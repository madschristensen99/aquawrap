import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { type Address } from "viem";

export interface Deployments {
  router: Address;
  twapRateProvider: Address;
  wrapRateProvider: Address;
  chainId: number;
}

const file = join(dirname(fileURLToPath(import.meta.url)), "..", "deployments.json");

export function loadDeployments(): Deployments {
  if (!existsSync(file)) {
    throw new Error(`deployments.json not found at ${file}. Run: npm run deploy`);
  }
  return JSON.parse(readFileSync(file, "utf8")) as Deployments;
}

export function saveDeployments(d: Deployments): void {
  writeFileSync(file, JSON.stringify(d, null, 2) + "\n");
  console.log(`Saved deployments to ${file}`);
}

/** Loads deployed bytecode from the forge build artifacts (out/). */
export function loadBytecode(contractName: string): `0x${string}` {
  const artifactPath = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "out", `${contractName}.sol`, `${contractName}.json`);
  const artifact = JSON.parse(readFileSync(artifactPath, "utf8"));
  const bytecode = artifact.bytecode?.object as string | undefined;
  if (!bytecode || bytecode === "0x") {
    throw new Error(`no bytecode for ${contractName}. Run: forge build`);
  }
  return bytecode as `0x${string}`;
}
