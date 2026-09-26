// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Context } from "@1inch/swap-vm/libs/VM.sol";
import { AquaOpcodes } from "@1inch/swap-vm/opcodes/AquaOpcodes.sol";

import { OracleSwap } from "../instructions/OracleSwap.sol";

/// @title AquaWrapOpcodes
/// @notice AquaOpcodes with one appended instruction: OracleSwap (0x22).
/// @dev The base AquaOpcodes v1.0.2 jump table occupies indices 0-33 (34 entries — the
///      assembly length trick in _opcodes() drops the first _notInstruction slot). We
///      append OracleSwap at index 34 (byte 0x22) — every existing opcode keeps its index,
///      so all existing programs behave identically. Byte 0x22 is out-of-bounds on the
///      deployed router (Panic 0x32), so OracleSwap programs only execute on AquaWrapRouter.
contract AquaWrapOpcodes is AquaOpcodes, OracleSwap {
    /// @dev Opcode byte of the appended OracleSwap instruction (index 34 in the jump table).
    uint8 public constant ORACLE_SWAP_OPCODE = 34;

    constructor(address aqua) AquaOpcodes(aqua) {}

    /// @dev Returns the base Aqua opcode table with OracleSwap appended at the end.
    function _opcodes() internal pure override returns (function(Context memory, bytes calldata) internal[] memory result) {
        function(Context memory, bytes calldata) internal[] memory base = super._opcodes();
        result = new function(Context memory, bytes calldata) internal[](base.length + 1);
        for (uint256 i = 0; i < base.length; i++) {
            result[i] = base[i];
        }
        result[base.length] = _oracleSwap;
    }
}
