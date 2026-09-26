import { type Address, concat, hexToBytes, bytesToHex } from "viem";

// Opcode byte of the appended OracleSwap instruction on AquaWrapRouter.
// The base AquaOpcodes v1.0.2 table has 34 entries (indices 0-33); OracleSwap is appended
// at index 34 = 0x22. On the deployed AquaSwapVMRouter this byte is out of bounds
// (Panic 0x32), so OracleSwap programs only execute on AquaWrapRouter.
export const ORACLE_SWAP_OPCODE = 0x22;
// Base table index of XYCSwap (used by the comparison script).
export const XYC_SWAP_OPCODE = 0x11;

export interface OracleSwapArgs {
  rateProvider: Address;
  feeBps: number;
}

/**
 * Encodes the full OracleSwap program:
 *   [0x22] [0x16 = 22] [20 bytes rateProvider] [2 bytes feeBps]
 */
export function encodeOracleSwapProgram({ rateProvider, feeBps }: OracleSwapArgs): `0x${string}` {
  const args = concat([rateProvider, bytesToHex(new Uint8Array([(feeBps >> 8) & 0xff, feeBps & 0xff]))]);
  return concat([
    bytesToHex(new Uint8Array([ORACLE_SWAP_OPCODE, 22])),
    args,
  ]);
}

/** Encodes a plain XYCSwap program: [0x11] [0x00] */
export function encodeXycProgram(): `0x${string}` {
  return bytesToHex(new Uint8Array([XYC_SWAP_OPCODE, 0]));
}

export function decodeOracleSwapProgram(program: `0x${string}`): OracleSwapArgs {
  const bytes = hexToBytes(program);
  if (bytes.length !== 24 || bytes[0] !== ORACLE_SWAP_OPCODE || bytes[1] !== 22) {
    throw new Error("not an OracleSwap program");
  }
  const rateProvider = bytesToHex(bytes.slice(2, 22)) as Address;
  const feeBps = (bytes[22] << 8) | bytes[23];
  return { rateProvider, feeBps };
}
