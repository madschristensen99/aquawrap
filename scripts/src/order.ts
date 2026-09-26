import { type Address, concat, bytesToHex, toBytes } from "viem";

// Mirrors MakerTraitsLib.build / TakerTraitsLib.build from swap-vm v1.0.2.

export interface MakerOrder {
  maker: Address;
  traits: bigint;
  data: `0x${string}`;
}

const SHOULD_UNWRAP = 1n << 255n;
const USE_AQUA_INSTEAD_OF_SIGNATURE = 1n << 254n;
const ALLOW_ZERO_AMOUNT_IN = 1n << 253n;

export function buildMakerOrder(opts: {
  maker: Address;
  program: `0x${string}`;
  useAquaInsteadOfSignature?: boolean;
  allowZeroAmountIn?: boolean;
}): MakerOrder {
  const traits =
    (opts.useAquaInsteadOfSignature !== false ? USE_AQUA_INSTEAD_OF_SIGNATURE : 0n) |
    (opts.allowZeroAmountIn ? ALLOW_ZERO_AMOUNT_IN : 0n);
  return {
    maker: opts.maker,
    traits,
    data: opts.program,
  };
}

// TakerTraits bit flags (v1.0.2)
const IS_EXACT_IN = 0x0001;
const IS_STRICT_THRESHOLD = 0x0010;
const IS_FIRST_TRANSFER_FROM_TAKER = 0x0020;
const USE_TRANSFER_FROM_AND_AQUA_PUSH = 0x0040;

export function buildTakerTraits(opts: {
  taker: Address;
  isExactIn: boolean;
  useTransferFromAndAquaPush?: boolean;
  threshold?: bigint; // min output (exactIn) or max input (exactOut)
  deadline?: number;
}): `0x${string}` {
  const threshold = opts.threshold !== undefined ? toBytes(opts.threshold, { size: 32 }) : new Uint8Array(0);
  const to = new Uint8Array(0);
  const deadline = opts.deadline ? new Uint8Array([...deadlineBytes(opts.deadline)]) : new Uint8Array(0);

  const index0 = threshold.length;
  const index1 = index0 + to.length;
  const index2 = index1 + deadline.length;
  // all remaining slices are empty -> indexes stay flat
  const index9 = index2;

  // index_i occupies bits [16 + 16*i, 32 + 16*i) of the uint160, which in big-endian
  // byte order is header bytes (18 - 2*i)..(19 - 2*i). index0 is the LAST two bytes.
  const slicesIndexes = new Uint8Array(20);
  const dv = new DataView(slicesIndexes.buffer);
  dv.setUint16(18, index0, false);
  dv.setUint16(16, index1, false);
  dv.setUint16(14, index2, false);
  dv.setUint16(12, index2, false);
  dv.setUint16(10, index2, false);
  dv.setUint16(8, index2, false);
  dv.setUint16(6, index2, false);
  dv.setUint16(4, index2, false);
  dv.setUint16(2, index2, false);
  dv.setUint16(0, index9, false);

  let flags = opts.isExactIn ? IS_EXACT_IN : 0;
  if (opts.useTransferFromAndAquaPush !== false) flags |= USE_TRANSFER_FROM_AND_AQUA_PUSH;
  if (opts.threshold !== undefined) flags |= IS_STRICT_THRESHOLD; // exact match on the threshold

  return bytesToHex(concat([slicesIndexes, new Uint8Array([flags >> 8, flags & 0xff]), threshold, to, deadline]));
}

function deadlineBytes(deadline: number): Uint8Array {
  const b = new Uint8Array(5);
  const dv = new DataView(b.buffer);
  dv.setUint32(0, deadline >>> 0, false);
  b[4] = (deadline >> 32) & 0xff;
  return b;
}
