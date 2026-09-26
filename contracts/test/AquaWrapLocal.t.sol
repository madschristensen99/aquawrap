// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "@1inch/swap-vm/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/libs/TakerTraits.sol";
import { AquaSwapVMRouter } from "@1inch/swap-vm/routers/AquaSwapVMRouter.sol";

import { AquaWrapRouter } from "../src/routers/AquaWrapRouter.sol";
import { MockRateProvider } from "./mocks/MockRateProvider.sol";

/// @title AquaWrapLocalTest
/// @notice Full ship -> quote -> swap -> dock flow on local mocks (no RPC needed).
/// @dev Uses a locally deployed Aqua registry, mock tokens and a settable mock rate
///      provider, so the whole lifecycle is testable in CI without a fork.
contract AquaWrapLocalTest is Test {
    uint8 internal constant ORACLE_SWAP_OPCODE = 34; // AquaWrapOpcodes.ORACLE_SWAP_OPCODE
    uint8 internal constant XYC_SWAP_OPCODE = 17; // base AquaOpcodes table index of XYCSwap
    uint256 internal constant RATE = 1.2e18;
    uint256 internal constant FEE_BPS = 30;

    Aqua internal aqua;
    TokenMock internal tokenA; // WETH-like
    TokenMock internal tokenB; // wstETH-like
    MockRateProvider internal rateProvider;
    AquaWrapRouter internal router;

    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");

    function setUp() public {
        aqua = new Aqua();
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);

        rateProvider = new MockRateProvider(address(tokenA), address(tokenB), RATE);
        router = new AquaWrapRouter(address(aqua), address(0), address(this), "AquaWrap", "1");

        tokenA.mint(maker, 1000e18);
        tokenB.mint(maker, 1000e18);
        vm.startPrank(maker);
        tokenA.approve(address(aqua), type(uint256).max);
        tokenB.approve(address(aqua), type(uint256).max);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════

    function _oracleSwapProgram() internal view returns (bytes memory) {
        return _oracleSwapProgram(FEE_BPS);
    }

    function _oracleSwapProgram(uint256 feeBps) internal view returns (bytes memory) {
        return abi.encodePacked(
            ORACLE_SWAP_OPCODE,
            uint8(22), // args length: 20 (rateProvider) + 2 (feeBps)
            address(rateProvider),
            uint16(feeBps)
        );
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

    function _ship(ISwapVM.Order memory order, uint256 balA, uint256 balB) internal returns (bytes32) {
        bytes32 orderHash = router.hash(order);
        bytes memory strategy = abi.encode(order);

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = balA;
        amounts[1] = balB;

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

    function _quote(ISwapVM.Order memory order, address tokenIn, address tokenOut, uint256 amount, bool isExactIn)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        bytes memory td = _takerData(isExactIn, "");
        (amountIn, amountOut, ) = router.asView().quote(order, tokenIn, tokenOut, amount, td);
    }

    function _swap(ISwapVM.Order memory order, address tokenIn, address tokenOut, uint256 amount, bool isExactIn, bytes memory threshold)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        vm.startPrank(taker);
        IERC20(tokenIn).approve(address(router), type(uint256).max);
        bytes memory td = _takerData(isExactIn, threshold);
        (amountIn, amountOut, ) = router.swap(order, tokenIn, tokenOut, amount, td);
        vm.stopPrank();
    }

    function _effectivePrice(uint256 amountOut, uint256 amountIn) internal pure returns (uint256) {
        return (amountOut * 1e18) / amountIn;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Tests
    // ═══════════════════════════════════════════════════════════════════

    function test_swap_pricesAtOracleRate() public {
        ISwapVM.Order memory order = _buildOrder(_oracleSwapProgram());
        _ship(order, 100e18, 120e18); // balanced at rate 1.2

        (uint256 amountIn, uint256 amountOut) = _quote(order, address(tokenA), address(tokenB), 1e18, true);
        uint256 price = _effectivePrice(amountOut, amountIn);
        assertApproxEqRel(price, RATE, 0.02e18, "pool must price at the oracle rate"); // fee 0.3% + slippage

        // execute the swap with a min-output threshold
        tokenA.mint(taker, 1e18);
        (amountIn, amountOut) = _swap(order, address(tokenA), address(tokenB), 1e18, true, abi.encodePacked(amountOut));
        assertEq(amountIn, 1e18);
        assertGt(amountOut, 0);

        // taker received real tokens
        assertEq(tokenB.balanceOf(taker), amountOut);
        // maker's Aqua balance decreased
        (uint256 balA, uint256 balB) = aqua.safeBalances(maker, address(router), router.hash(order), address(tokenA), address(tokenB));
        assertEq(balA, 101e18); // taker pushed 1 tokenA
        assertEq(balB, 120e18 - amountOut);
    }

    function test_swap_bothDirections() public {
        ISwapVM.Order memory order = _buildOrder(_oracleSwapProgram());
        _ship(order, 100e18, 120e18);

        // A -> B
        (uint256 inAB, uint256 outAB) = _quote(order, address(tokenA), address(tokenB), 1e18, true);
        // B -> A
        (uint256 inBA, uint256 outBA) = _quote(order, address(tokenB), address(tokenA), 1e18, true);

        // reciprocal prices (round-trip loses fee + slippage both ways)
        assertApproxEqRel(_effectivePrice(outAB, inAB) * _effectivePrice(outBA, inBA), 1e36, 0.05e18);
    }

    function test_rateDrift_recentersCurve() public {
        // identical reserves on two strategies: OracleSwap (0 fee, isolates rate tracking) vs plain XYC
        ISwapVM.Order memory oracleOrder = _buildOrder(_oracleSwapProgram(0));
        ISwapVM.Order memory xycOrder = _buildOrder(_xycProgram());
        _ship(oracleOrder, 100e18, 120e18);
        _ship(xycOrder, 100e18, 120e18);

        // tiny trade so slippage is negligible and the rate-tracking signal dominates
        uint256 amount = 1e15;

        // at ship-time rate both price at ~1.2
        (, uint256 oracleOut) = _quote(oracleOrder, address(tokenA), address(tokenB), amount, true);
        (, uint256 xycOut) = _quote(xycOrder, address(tokenA), address(tokenB), amount, true);
        assertApproxEqRel(_effectivePrice(oracleOut, amount), RATE, 0.01e18);
        assertApproxEqRel(_effectivePrice(xycOut, amount), RATE, 0.01e18);

        // rate drifts 1.2 -> 1.18 (wrapped token loses value)
        rateProvider.setRate(1.18e18);

        (, oracleOut) = _quote(oracleOrder, address(tokenA), address(tokenB), amount, true);
        (, xycOut) = _quote(xycOrder, address(tokenA), address(tokenB), amount, true);

        uint256 oraclePrice = _effectivePrice(oracleOut, amount);
        uint256 xycPrice = _effectivePrice(xycOut, amount);

        emit log_named_uint("OracleSwap price", oraclePrice);
        emit log_named_uint("XYC price", xycPrice);

        // OracleSwap re-anchors to the live rate; XYC stays stale at the reserve ratio
        assertApproxEqRel(oraclePrice, 1.18e18, 0.01e18, "OracleSwap must track the live rate");
        assertApproxEqRel(xycPrice, 1.2e18, 0.01e18, "XYC stays at the ship-time reserve ratio");
        assertLt(absDiff(oraclePrice, 1.18e18), absDiff(xycPrice, 1.18e18), "oracle pool must be closer to the live rate");
    }

    function test_exactOut() public {
        ISwapVM.Order memory order = _buildOrder(_oracleSwapProgram());
        _ship(order, 100e18, 120e18);

        (uint256 amountIn, uint256 amountOut) = _quote(order, address(tokenA), address(tokenB), 1e18, false);
        assertEq(amountOut, 1e18);
        assertGt(amountIn, 0);

        tokenA.mint(taker, amountIn);
        (amountIn, amountOut) = _swap(order, address(tokenA), address(tokenB), 1e18, false, abi.encodePacked(amountIn));
        assertEq(amountOut, 1e18);
        assertEq(tokenB.balanceOf(taker), 1e18);
    }

    function test_quoteSwapParity_fuzz(uint256 amount) public {
        amount = bound(amount, 1e6, 10e18);

        ISwapVM.Order memory order = _buildOrder(_oracleSwapProgram());
        _ship(order, 100e18, 120e18);

        (uint256 qIn, uint256 qOut) = _quote(order, address(tokenA), address(tokenB), amount, true);

        tokenA.mint(taker, amount);
        (uint256 sIn, uint256 sOut) = _swap(order, address(tokenA), address(tokenB), amount, true, abi.encodePacked(qOut));

        // rate provider is a view call: same value within a block -> quote == swap
        assertEq(sIn, qIn, "amountIn must match quote");
        assertEq(sOut, qOut, "amountOut must match quote");
    }

    function test_dock() public {
        ISwapVM.Order memory order = _buildOrder(_oracleSwapProgram());
        bytes32 orderHash = _ship(order, 100e18, 120e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        vm.prank(maker);
        aqua.dock(address(router), orderHash, tokens);

        (uint256 balA, uint256 balB) = aqua.rawBalances(maker, address(router), orderHash, address(tokenA));
        assertEq(balA, 0);
        (balA, balB) = aqua.rawBalances(maker, address(router), orderHash, address(tokenB));
        assertEq(balA, 0);

        // safeBalances reverts for a docked strategy
        vm.expectRevert();
        aqua.safeBalances(maker, address(router), orderHash, address(tokenA), address(tokenB));
    }

    function test_baseOpcodesStillWork() public {
        // a plain XYC program must execute on AquaWrapRouter unchanged (backward compat)
        ISwapVM.Order memory order = _buildOrder(_xycProgram());
        _ship(order, 100e18, 200e18);

        (, uint256 amountOut) = _quote(order, address(tokenA), address(tokenB), 50e18, true);
        uint256 expected = uint256(50e18) * uint256(200e18) / uint256(150e18);
        assertEq(amountOut, expected);
    }

    function test_oracleSwapUnknownOnBaseRouter() public {
        // the OracleSwap opcode (0x23) is out of bounds on the vanilla AquaSwapVMRouter
        // (35-entry table, indices 0-34) -> Panic(0x32)
        AquaSwapVMRouter baseRouter = new AquaSwapVMRouter(address(aqua), address(0), address(this), "Base", "1");
        ISwapVM.Order memory order = _buildOrder(_oracleSwapProgram());

        bytes32 orderHash = baseRouter.hash(order);
        bytes memory strategy = abi.encode(order);
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 120e18;
        vm.prank(maker);
        aqua.ship(address(baseRouter), strategy, tokens, amounts);

        bytes memory td = _takerData(true, "");
        ISwapVM baseView = baseRouter.asView();
        vm.expectRevert(); // Panic(0x32): array out-of-bounds
        baseView.quote(order, address(tokenA), address(tokenB), 1e18, td);
    }

    function test_unknownOpcodeReverts() public {
        ISwapVM.Order memory order = _buildOrder(abi.encodePacked(uint8(99), uint8(0)));
        _ship(order, 100e18, 120e18);

        bytes memory td = _takerData(true, "");
        ISwapVM viewRouter = router.asView();
        vm.expectRevert(); // Panic(0x32)
        viewRouter.quote(order, address(tokenA), address(tokenB), 1e18, td);
    }

    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
