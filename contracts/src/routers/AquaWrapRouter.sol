// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Context } from "@1inch/swap-vm/libs/VM.sol";
import { Simulator } from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";

import { SwapVM } from "@1inch/swap-vm/SwapVM.sol";
import { AquaWrapOpcodes } from "../opcodes/AquaWrapOpcodes.sol";

/// @title AquaWrapRouter
/// @notice AquaSwapVMRouter with one appended instruction: OracleSwap (0x23).
/// @dev The official Aqua registry is used unchanged; only the SwapVM router (the "app"
///      address) is redeployed, which the 1inch bounty rules explicitly allow.
///      Every existing opcode (0x00-0x22) delegates to the base AquaOpcodes table —
///      existing programs behave identically.
contract AquaWrapRouter is Simulator, SwapVM, AquaWrapOpcodes {
    /// @notice Deploy router with Aqua and WETH addresses
    /// @param aqua Address of the Aqua protocol contract (registry)
    /// @param weth Address of the WETH token (unwrap support)
    /// @param owner Address of the owner of the router. Only owner can rescue funds.
    /// @param name EIP-712 domain name
    /// @param version EIP-712 domain version
    constructor(address aqua, address weth, address owner, string memory name, string memory version)
        SwapVM(aqua, weth, owner, name, version)
        AquaWrapOpcodes(aqua)
    {}

    /// @dev Returns the instruction set: base Aqua table + OracleSwap appended.
    function _instructions() internal pure override returns (function(Context memory, bytes calldata) internal[] memory result) {
        return _opcodes();
    }
}
