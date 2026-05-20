/**
 * receiveAttestation.ts
 *
 * 从 Circle Attestation Service V2 获取消息证据，调用 CCTPV2Core.receiveUSDC 完成跨链接收。
 *
 * Circle V2 API：GET https://iris-api.circle.com/v2/cctp/messages/{messageHash}
 *   响应：{ "attestation": "0x...", "message": "0x..." }
 *
 * 用法：
 *   npx hardhat run scripts/receiveAttestation.ts --network sepolia
 *
 *   环境变量：MESSAGE_HASH, CCTP_CONTRACT, RPC_URL, PRIVATE_KEY, CHAIN_ID
 */

import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia, mainnet, base, arbitrum, optimism } from "viem/chains";

// ============================================================
// 支持的链
// ============================================================
type SupportedChain = typeof sepolia | typeof mainnet | typeof base | typeof arbitrum | typeof optimism;

const CHAIN_BY_ID: Record<number, SupportedChain> = {
  1: mainnet,
  11155111: sepolia,
  8453: base,
  42161: arbitrum,
  10: optimism,
};

function getChain(chainId: number): SupportedChain {
  const c = CHAIN_BY_ID[chainId];
  if (!c) throw new Error(`Unsupported chain ID: ${chainId}`);
  return c;
}

// ============================================================
// ABI
// ============================================================
const ABI = {
  receiveUSDC: {
    type: "function",
    inputs: [
      { name: "message", type: "bytes" },
      { name: "attestation", type: "bytes" },
    ],
    outputs: [{ type: "bool" }],
    stateMutability: "nonpayable",
  } as const,
  isMessageProcessed: {
    type: "function",
    inputs: [{ name: "message", type: "bytes" }],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  } as const,
} as const;

// ============================================================
// Circle V2 API
// ============================================================
const CIRCLE_API = "https://iris-api.circle.com/v2/cctp/messages";

interface CircleV2Response {
  message: string;
  attestation: string;
}

async function fetchAttestation(messageHash: string): Promise<CircleV2Response> {
  const res = await fetch(`${CIRCLE_API}/${messageHash}`, { headers: { Accept: "application/json" } });
  if (!res.ok) throw new Error(`Circle API ${res.status}: ${await res.text()}`);
  return res.json() as Promise<CircleV2Response>;
}

async function waitForAttestation(messageHash: string, timeoutSec = 300, intervalMs = 5000) {
  const deadline = Date.now() + timeoutSec * 1000;
  while (Date.now() < deadline) {
    try {
      const data = await fetchAttestation(messageHash);
      if (data.attestation && data.attestation !== "0x") return data;
    } catch {
      // continue polling
    }
    process.stdout.write(".");
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error("Timeout waiting for attestation");
}

// ============================================================
// main
// ============================================================
async function main() {
  const messageHash = (process.env.MESSAGE_HASH || "") as `0x${string}`;
  const cctpContract = (process.env.CCTP_CONTRACT || "") as `0x${string}`;
  const rpcUrl = process.env.RPC_URL || "";
  const privateKey = (process.env.PRIVATE_KEY || "") as `0x${string}`;
  const chainId = parseInt(process.env.CHAIN_ID || "1");

  if (!messageHash || !cctpContract || !rpcUrl || !privateKey) {
    console.error("Missing env: MESSAGE_HASH, CCTP_CONTRACT, RPC_URL, PRIVATE_KEY");
    process.exit(1);
  }

  const chain = getChain(chainId);

  console.log("=".repeat(60));
  console.log("CCTP V2 — Receive Attestation");
  console.log("=".repeat(60));
  console.log(`Message Hash : ${messageHash}`);
  console.log(`CCTP        : ${cctpContract}`);
  console.log(`Chain       : ${chain.name} (${chainId})`);

  // Step 1: 获取 attestation
  console.log("\n[1] Fetching attestation from Circle V2 API...");
  process.stdout.write("  Waiting");
  const circleData = await waitForAttestation(messageHash);
  console.log("\n  Received!");
  const message = circleData.message as `0x${string}`;
  const attestation = circleData.attestation as `0x${string}`;
  console.log(`  Message      : ${message.slice(0, 42)}...`);
  console.log(`  Attestation  : ${attestation.slice(0, 42)}... (${Math.floor(attestation.length / 2)} bytes)`);

  // Step 2: 检查是否已处理
  console.log("\n[2] Checking processed status...");
  const publicClient = createPublicClient({ transport: http(rpcUrl), chain });

  const isProcessed = await publicClient.readContract({
    address: cctpContract,
    abi: [ABI.isMessageProcessed],
    functionName: "isMessageProcessed",
    args: [message],
  });

  if (isProcessed) {
    console.warn("  [SKIP] Message already processed.");
    process.exit(0);
  }
  console.log("  [OK] Not yet processed.");

  // Step 3: 发送 receiveUSDC
  console.log("\n[3] Sending receiveUSDC...");
  const account = privateKeyToAccount(privateKey);
  const walletClient = createWalletClient({ account, transport: http(rpcUrl), chain });

  const hash = await walletClient.writeContract({
    address: cctpContract,
    abi: [ABI.receiveUSDC],
    functionName: "receiveUSDC",
    args: [message, attestation],
  });

  console.log(`  TX Hash  : ${hash}`);
  const explorer = chain.blockExplorers?.default.url;
  if (explorer) console.log(`  Explorer : ${explorer}/tx/${hash}`);

  // Step 4: 等待确认
  console.log("\n[4] Waiting for confirmation...");
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`  Block    : ${receipt.blockNumber}`);
  console.log(`  Status   : ${receipt.status === "success" ? "SUCCESS" : "FAILED"}`);
  console.log(`  Gas Used : ${receipt.gasUsed.toLocaleString()}`);

  if (receipt.status === "success") {
    console.log("\n[CCTP] USDC received successfully!");
  } else {
    console.error("\n[CCTP] receiveUSDC failed.");
    process.exit(1);
  }
}

main().catch((e) => {
  console.error("\n[ERROR]", e);
  process.exit(1);
});
