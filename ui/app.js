import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  formatUnits,
  parseUnits,
  concat,
  bytesToHex,
  toBytes,
  getContract,
} from "https://esm.sh/viem@2";
import { mainnet } from "https://esm.sh/viem@2/chains";

import { CONFIG } from "./config.js";

// ─────────────────────────────────────────────────────────────────────────────
// Constants & ABIs (mirror scripts/src/*)
// ─────────────────────────────────────────────────────────────────────────────
const ORACLE_SWAP_OPCODE = 0x22; // appended opcode on AquaWrapRouter
const XYC_SWAP_OPCODE = 0x11; // base table index of XYCSwap
const USE_AQUA = 1n << 254n;

const erc20Abi = [
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }], outputs: [{ name: "", type: "bool" }] },
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "account", type: "address" }], outputs: [{ name: "", type: "uint256" }] },
  { type: "function", name: "allowance", stateMutability: "view", inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }], outputs: [{ name: "", type: "uint256" }] },
];

const rateProviderAbi = [
  { type: "function", name: "getRate", stateMutability: "view", inputs: [{ name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" }], outputs: [{ name: "rate", type: "uint256" }] },
];

const aquaAbi = [
  { type: "function", name: "safeBalances", stateMutability: "view", inputs: [{ name: "maker", type: "address" }, { name: "app", type: "address" }, { name: "strategyHash", type: "bytes32" }, { name: "token0", type: "address" }, { name: "token1", type: "address" }], outputs: [{ name: "balance0", type: "uint256" }, { name: "balance1", type: "uint256" }] },
];

const routerAbi = [
  { type: "function", name: "hash", stateMutability: "view", inputs: [{ name: "order", type: "tuple", components: [{ name: "maker", type: "address" }, { name: "traits", type: "uint256" }, { name: "data", type: "bytes" }] }], outputs: [{ name: "", type: "bytes32" }] },
  { type: "function", name: "quote", stateMutability: "view", inputs: [{ name: "order", type: "tuple", components: [{ name: "maker", type: "address" }, { name: "traits", type: "uint256" }, { name: "data", type: "bytes" }] }, { name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" }, { name: "amount", type: "uint256" }, { name: "takerTraitsAndData", type: "bytes" }], outputs: [{ name: "amountIn", type: "uint256" }, { name: "amountOut", type: "uint256" }, { name: "orderHash", type: "bytes32" }] },
  { type: "function", name: "swap", stateMutability: "nonpayable", inputs: [{ name: "order", type: "tuple", components: [{ name: "maker", type: "address" }, { name: "traits", type: "uint256" }, { name: "data", type: "bytes" }] }, { name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" }, { name: "amount", type: "uint256" }, { name: "takerTraitsAndData", type: "bytes" }], outputs: [{ name: "amountIn", type: "uint256" }, { name: "amountOut", type: "uint256" }, { name: "orderHash", type: "bytes32" }] },
];

// ─────────────────────────────────────────────────────────────────────────────
// Program / order / traits encoding (mirrors swap-vm v1.0.2 libs)
// ─────────────────────────────────────────────────────────────────────────────
function encodeOracleSwapProgram(rateProvider, feeBps) {
  return concat([
    bytesToHex(new Uint8Array([ORACLE_SWAP_OPCODE, 22])),
    concat([rateProvider, bytesToHex(new Uint8Array([(feeBps >> 8) & 0xff, feeBps & 0xff]))]),
  ]);
}

function encodeXycProgram() {
  return bytesToHex(new Uint8Array([XYC_SWAP_OPCODE, 0]));
}

function buildMakerOrder(maker, program) {
  return { maker, traits: USE_AQUA, data: program };
}

function buildTakerTraits({ isExactIn, threshold }) {
  const IS_EXACT_IN = 0x0001;
  const IS_STRICT_THRESHOLD = 0x0010;
  const USE_PUSH = 0x0040;

  const thresholdBytes = threshold !== undefined ? toBytes(threshold, { size: 32 }) : new Uint8Array(0);
  const index0 = thresholdBytes.length;

  const slicesIndexes = new Uint8Array(20);
  const dv = new DataView(slicesIndexes.buffer);
  for (let i = 0; i < 10; i++) dv.setUint16(18 - 2 * i, index0, false);

  let flags = isExactIn ? IS_EXACT_IN : 0;
  flags |= USE_PUSH;
  if (threshold !== undefined) flags |= IS_STRICT_THRESHOLD;

  return bytesToHex(concat([slicesIndexes, new Uint8Array([flags >> 8, flags & 0xff]), thresholdBytes]));
}

// ─────────────────────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────────────────────
const publicClient = createPublicClient({ chain: mainnet, transport: http(CONFIG.rpcUrl) });

let walletClient = null;
let account = null;
let orderHash = null;

const $ = (id) => document.getElementById(id);

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────
const fmt = (v, d = 18) => formatUnits(v, d);
const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const bps = (a, b) => (a > b ? ((a - b) * 10000n) / b : ((b - a) * 10000n) / b);

function setNet(ok, label) {
  $("net-dot").classList.toggle("ok", ok);
  $("net-label").textContent = label;
}

// ─────────────────────────────────────────────────────────────────────────────
// Data loading
// ─────────────────────────────────────────────────────────────────────────────
let lastUpdated = null;

function stampUpdated() {
  lastUpdated = new Date();
  $("rate-updated").textContent = lastUpdated.toLocaleTimeString();
}

async function loadRates() {
  const [twap, wrap] = await Promise.all([
    publicClient.readContract({ address: CONFIG.twapProvider, abi: rateProviderAbi, functionName: "getRate", args: [CONFIG.weth, CONFIG.wsteth] }),
    publicClient.readContract({ address: CONFIG.wrapProvider, abi: rateProviderAbi, functionName: "getRate", args: [CONFIG.weth, CONFIG.wsteth] }),
  ]);
  $("rate-twap").textContent = fmt(twap);
  $("rate-wrap").textContent = fmt(wrap);
  $("rate-window").textContent = `${CONFIG.twapWindow / 60} min`;
  $("rate-pool").textContent = short(CONFIG.pool);
  stampUpdated();
  return twap;
}

async function loadPosition() {
  const program = encodeOracleSwapProgram(CONFIG.twapProvider, CONFIG.feeBps);
  const order = buildMakerOrder(CONFIG.maker, program);
  orderHash = await publicClient.readContract({ address: CONFIG.router, abi: routerAbi, functionName: "hash", args: [order] });

  const [balWeth, balWsteth] = await publicClient.readContract({
    address: CONFIG.aqua,
    abi: aquaAbi,
    functionName: "safeBalances",
    args: [CONFIG.maker, CONFIG.router, orderHash, CONFIG.weth, CONFIG.wsteth],
  });

  $("pos-weth").textContent = fmt(balWeth);
  $("pos-wsteth").textContent = fmt(balWsteth);
  $("pos-hash").textContent = short(orderHash);
  $("pos-maker").textContent = short(CONFIG.maker);
  $("pos-fee").textContent = `${CONFIG.feeBps} bps`;
  $("pos-status").textContent = "active";
}

async function quote(amount) {
  const program = encodeOracleSwapProgram(CONFIG.twapProvider, CONFIG.feeBps);
  const order = buildMakerOrder(CONFIG.maker, program);
  const takerData = buildTakerTraits({ isExactIn: true });

  const [, qOut] = await publicClient.readContract({
    address: CONFIG.router,
    abi: routerAbi,
    functionName: "quote",
    args: [order, CONFIG.weth, CONFIG.wsteth, amount, takerData],
  });
  return qOut;
}

async function refreshQuote() {
  const amount = $("amount").value;
  if (!amount || Number(amount) <= 0) {
    $("output").value = "";
    $("swap-effective").textContent = "—";
    $("swap-slippage").textContent = "—";
    return;
  }
  try {
    const wei = parseUnits(String(amount), 18);
    const qOut = await quote(wei);
    const twap = await loadRates();

    $("output").value = fmt(qOut);
    $("swap-oracle").textContent = fmt(twap);
    const effective = (qOut * 10n ** 18n) / wei;
    $("swap-effective").textContent = fmt(effective);
    $("swap-slippage").textContent = `${bps(twap, effective)} bps`;
    $("swap-fee").textContent = `${CONFIG.feeBps} bps`;
  } catch (e) {
    $("swap-hint").textContent = `quote failed: ${e.shortMessage ?? e.message}`;
  }
}

async function loadCompare() {
  const liveRate = await publicClient.readContract({ address: CONFIG.twapProvider, abi: rateProviderAbi, functionName: "getRate", args: [CONFIG.weth, CONFIG.wsteth] });
  const amount = 10n ** 15n; // tiny trade: negligible slippage
  const takerData = buildTakerTraits({ isExactIn: true });

  const strategies = [
    { id: "cmp-oracle", name: "OracleSwap", program: encodeOracleSwapProgram(CONFIG.twapProvider, 0) },
    { id: "cmp-xyc", name: "XYCSwap", program: encodeXycProgram() },
  ];

  for (const s of strategies) {
    const order = buildMakerOrder(CONFIG.maker, s.program);
    const [, qOut] = await publicClient.readContract({
      address: CONFIG.router,
      abi: routerAbi,
      functionName: "quote",
      args: [order, CONFIG.weth, CONFIG.wsteth, amount, takerData],
    });
    const price = (qOut * 10n ** 18n) / amount;
    const row = $(s.id);
    row.children[1].textContent = fmt(price);
    row.children[2].textContent = `${bps(liveRate, price)} bps`;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Wallet + swap
// ─────────────────────────────────────────────────────────────────────────────
async function connect() {
  if (!window.ethereum) {
    $("swap-hint").textContent = "No wallet found — install MetaMask or similar.";
    return;
  }
  walletClient = createWalletClient({ chain: mainnet, transport: custom(window.ethereum) });
  [account] = await walletClient.requestAddresses();
  $("swap-btn").textContent = `Swap 1 WETH → wstETH (${short(account)})`;
  $("swap-btn").disabled = false;
  $("swap-hint").textContent = "Executes onchain: router pushes WETH to the maker's Aqua balance and pulls wstETH to you.";
  await refreshWalletBalances();
}

async function refreshWalletBalances() {
  if (!account) return;
  const [weth, wsteth] = await Promise.all([
    publicClient.readContract({ address: CONFIG.weth, abi: erc20Abi, functionName: "balanceOf", args: [account] }),
    publicClient.readContract({ address: CONFIG.wsteth, abi: erc20Abi, functionName: "balanceOf", args: [account] }),
  ]);
  $("wallet-balances").hidden = false;
  $("wallet-weth").textContent = `${fmt(weth)} WETH`;
  $("wallet-wsteth").textContent = `${fmt(wsteth)} wstETH`;
}

async function doSwap() {
  const btn = $("swap-btn");
  btn.classList.add("loading");
  btn.textContent = "Swapping…";
  try {
    const amount = parseUnits(String($("amount").value || "1"), 18);
    const qOut = await quote(amount);
    const program = encodeOracleSwapProgram(CONFIG.twapProvider, CONFIG.feeBps);
    const order = buildMakerOrder(CONFIG.maker, program);
    const takerData = buildTakerTraits({ isExactIn: true, threshold: qOut });

    const weth = getContract({ address: CONFIG.weth, abi: erc20Abi, client: walletClient });
    const allowance = await publicClient.readContract({ address: CONFIG.weth, abi: erc20Abi, functionName: "allowance", args: [account, CONFIG.router] });
    if (allowance < amount) {
      $("swap-hint").textContent = "Approving WETH…";
      const tx = await weth.write.approve([CONFIG.router, 2n ** 256n - 1n]);
      await publicClient.waitForTransactionReceipt({ hash: tx });
    }

    $("swap-hint").textContent = "Executing swap…";
    const hash = await walletClient.writeContract({
      address: CONFIG.router,
      abi: routerAbi,
      functionName: "swap",
      args: [order, CONFIG.weth, CONFIG.wsteth, amount, takerData],
      account,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    $("swap-hint").textContent = `Swap executed: ${receipt.transactionHash.slice(0, 10)}…${receipt.transactionHash.slice(-8)}`;
    await Promise.all([loadPosition(), refreshWalletBalances()]);
  } catch (e) {
    $("swap-hint").textContent = `swap failed: ${e.shortMessage ?? e.message}`;
  } finally {
    btn.classList.remove("loading");
    btn.textContent = `Swap (${short(account)})`;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Init
// ─────────────────────────────────────────────────────────────────────────────
async function refreshAll() {
  await Promise.all([loadRates(), loadPosition(), loadCompare()]);
  await refreshQuote();
  if (account) await refreshWalletBalances();
}

async function init() {
  $("swap-btn").addEventListener("click", account ? doSwap : connect);
  $("amount").addEventListener("input", refreshQuote);
  $("refresh-btn").addEventListener("click", refreshAll);

  try {
    await Promise.all([loadRates(), loadPosition(), loadCompare()]);
    setNet(true, "mainnet · live");
    await refreshQuote();
    setInterval(refreshQuote, 12000);
  } catch (e) {
    setNet(false, "error");
    $("swap-hint").textContent = `init failed: ${e.shortMessage ?? e.message}`;
    console.error(e);
  }
}

init();
