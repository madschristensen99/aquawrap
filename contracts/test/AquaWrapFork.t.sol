// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/libs/TakerTraits.sol";

import { AquaWrapRouter } from "../src/routers/AquaWrapRouter.sol";
import { TWAPRateProvider } from "../src/oracles/TWAPRateProvider.sol";
import { WrapRateProvider } from "../src/oracles/WrapRateProvider.sol";

/// @title AquaWrapForkTest
/// @notice Mainnet fork: ship -> quote -> swap -> dock against the REAL Aqua registry,
///         real WETH/wstETH and a real Uniswap V3 TWAP oracle.
/// @dev Requires MAINNET_RPC_URL. Skipped automatically when it is not set.
contract AquaWrapForkTest is Test {
    uint8 internal constant ORACLE_SWAP_OPCODE = 34;
    uint8 internal constant XYC_SWAP_OPCODE = 17;
    uint256 internal constant FEE_BPS = 30;

    // Ethereum mainnet (verified addresses)
    address internal constant AQUA_REGISTRY = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    // Uniswap V3 wstETH/WETH 0.01% pool (token0 = wstETH, token1 = WETH)
    address internal constant UNI_V3_WSTETH_WETH_POOL = 0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa;
    // Chainlink stETH/ETH feed (ETH per stETH, 8 decimals, 24h heartbeat)
    address internal constant CHAINLINK_STETH_ETH = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;

    IAqua internal constant aqua = IAqua(AQUA_REGISTRY);

    AquaWrapRouter internal router;
    TWAPRateProvider internal twapProvider;
    WrapRateProvider internal wrapProvider;

    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        twapProvider = new TWAPRateProvider(UNI_V3_WSTETH_WETH_POOL, WETH, WSTETH, 1800);
        wrapProvider = new WrapRateProvider(WSTETH, WETH, CHAINLINK_STETH_ETH, 86400);
        router = new AquaWrapRouter(AQUA_REGISTRY, WETH, address(this), "AquaWrap", "1");

        deal(WETH, maker, 1000e18);
        deal(WSTETH, maker, 1000e18);
        vm.startPrank(maker);
        IERC20(WETH).approve(AQUA_REGISTRY, type(uint256).max);
        IERC20(WSTETH).approve(AQUA_REGISTRY, type(uint256).max);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════

    function _oracleSwapProgram(address rateProvider) internal pure returns (bytes memory) {
        return abi.encodePacked(ORACLE_SWAP_OPCODE, uint8(22), rateProvider, uint16(FEE_BPS));
    }

    function _xycProgram() internal pure returns (bytes memory) {
        return abi.encodePacked(XYC_SWAP_OPCODE, uint8(0));
    }

    function _buildOrder(bytes memory program) internal view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: program
        }));
    }

    function _ship(ISwapVM.Order memory order, uint256 balIn, uint256 balOut) internal returns (bytes32) {
        bytes32 orderHash = router.hash(order);
        bytes memory strategy = abi.encode(order);

        address[] memory tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = WSTETH;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = balIn;
        amounts[1] = balOut;

        vm.prank(maker);
        bytes32 strategyHash = aqua.ship(address(router), strategy, tokens, amounts);
        assertEq(strategyHash, orderHash, "strategyHash must equal orderHash");
        return strategyHash;
    }

    function _takerData(bool isExactIn, bytes memory threshold) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            threshold: threshold,
            to: address(0),
            deadline: 0,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));
    }

    function _quote(ISwapVM.Order memory order, uint256 amount, bool isExactIn)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        bytes memory td = _takerData(isExactIn, "");
        (amountIn, amountOut, ) = router.asView().quote(order, WETH, WSTETH, amount, td);
    }

    function _swap(ISwapVM.Order memory order, uint256 amount, bool isExactIn, bytes memory threshold)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        vm.startPrank(taker);
        IERC20(WETH).approve(address(router), type(uint256).max);
        bytes memory td = _takerData(isExactIn, threshold);
        (amountIn, amountOut, ) = router.swap(order, WETH, WSTETH, amount, td);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_twapProvider_readsLiveRate() public {
        uint256 rate = twapProvider.getRate(WETH, WSTETH);
        emit log_named_uint("TWAP rate (wstETH per WETH)", rate);
        // wstETH per WETH is ~0.85 (1 wstETH ~= 1.17 ETH); sanity bounds
        assertGt(rate, 0.5e18);
        assertLt(rate, 1.5e18);
    }

    function test_wrapProvider_matchesTwap() public {
        uint256 twap = twapProvider.getRate(WETH, WSTETH);
        uint256 wrap = wrapProvider.getRate(WETH, WSTETH);
        emit log_named_uint("TWAP rate (wstETH per WETH)", twap);
        emit log_named_uint("Wrap rate (wstETH per WETH)", wrap);
        assertApproxEqRel(twap, wrap, 0.05e18, "wrap rate and TWAP should be close");
    }

    function test_oracleSwap_tracksTwap_xycIsStale() public {
        // Ship an imbalanced pool: 100 WETH + 100 wstETH (reserve ratio 1.0),
        // while the live oracle says ~0.85 wstETH per WETH.
        ISwapVM.Order memory oracleOrder = _buildOrder(_oracleSwapProgram(address(twapProvider)));
        ISwapVM.Order memory xycOrder = _buildOrder(_xycProgram());
        _ship(oracleOrder, 100e18, 100e18);
        _ship(xycOrder, 100e18, 100e18);

        uint256 liveRate = twapProvider.getRate(WETH, WSTETH);

        (, uint256 oracleOut) = _quote(oracleOrder, 1e18, true);
        (, uint256 xycOut) = _quote(xycOrder, 1e18, true);

        uint256 oraclePrice = (oracleOut * 1e18) / 1e18;
        uint256 xycPrice = (xycOut * 1e18) / 1e18;

        emit log_named_uint("Live TWAP rate (wstETH per WETH)", liveRate);
        emit log_named_uint("OracleSwap price (wstETH per WETH)", oraclePrice);
        emit log_named_uint("XYC price (wstETH per WETH)", xycPrice);

        // OracleSwap re-anchors to the live rate; XYC is stuck at the reserve ratio
        assertApproxEqRel(oraclePrice, liveRate, 0.02e18, "OracleSwap must track the TWAP");
        assertLt(absDiff(oraclePrice, liveRate), absDiff(xycPrice, liveRate), "oracle pool must be closer to the live rate");
    }

    function test_swap_onchainTokenTransfer() public {
        ISwapVM.Order memory order = _buildOrder(_oracleSwapProgram(address(twapProvider)));
        _ship(order, 100e18, 85e18); // roughly balanced at the live rate

        (, uint256 qOut) = _quote(order, 1e18, true);
        assertGt(qOut, 0);

        deal(WETH, taker, 1e18);
        uint256 takerWstEthBefore = IERC20(WSTETH).balanceOf(taker);
        (uint256 amountIn, uint256 amountOut) = _swap(order, 1e18, true, abi.encodePacked(qOut));
        uint256 takerWstEthAfter = IERC20(WSTETH).balanceOf(taker);

        emit log_named_uint("Taker paid (WETH)", amountIn);
        emit log_named_uint("Taker received (wstETH)", amountOut);

        assertEq(amountIn, 1e18);
        assertEq(takerWstEthAfter - takerWstEthBefore, amountOut, "taker must receive real wstETH onchain");
        assertGt(amountOut, 0);
    }

    function test_dock() public {
        ISwapVM.Order memory order = _buildOrder(_oracleSwapProgram(address(twapProvider)));
        bytes32 orderHash = _ship(order, 100e18, 85e18);

        address[] memory tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = WSTETH;
        vm.prank(maker);
        aqua.dock(address(router), orderHash, tokens);

        (uint256 balance, ) = aqua.rawBalances(maker, address(router), orderHash, WETH);
        assertEq(balance, 0);
    }

    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
