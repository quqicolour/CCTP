/**
 * sendCCTP.ts
 *
 * 通过 CCTPV2Core 发送跨链 USDC（depositForBurn）。
 *
 * 用法：
 *   npx hardhat run scripts/sendCCTP.ts --network sepolia
 *
 *   环境变量：RPC_URL, PRIVATE_KEY, CCTP_CONTRACT,
 *            DESTINATION_DOMAIN, MINT_RECIPIENT, SOURCE_USDC, AMOUNT
 */

import { createPublicClient, createWalletClient, http, parseUnits, type Chain } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia, mainnet, base, arbitrum, optimism } from "viem/chains";

// ============================================================
// Chain map — 所有链 cast 为 Chain 以避免字面量类型冲突
// ============================================================
const CHAIN_MAP: Record<number, Chain> = {
  1: mainnet as Chain,
  11155111: sepolia as Chain,
  8453: base as Chain,
  42161: arbitrum as Chain,
  10: optimism as Chain,
};

function getChain(chainId: number): Chain {
  const c = CHAIN_MAP[chainId];
  if (!c) throw new Error(`Unsupported chain ID: ${chainId}`);
  return c;
}

// ============================================================
// ABI
// ============================================================
const CCTP_ABI = [
  {
    type: "function",
    name: "sendUSDC",
    inputs: [
      { name: "amount", type: "uint256" },
      { name: "destinationDomain", type: "uint32" },
      { name: "mintRecipient", type: "bytes32" },
      { name: "burnToken", type: "address" },
    ],
    outputs: [{ name: "nonce", type: "uint64" }],
    stateMutability: "nonpayable",
  },
] as const;

const USDC_ABI = [
  {
    name: "balanceOf",
    type: "function",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    name: "allowance",
    type: "function",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    name: "approve",
    type: "function",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
    stateMutability: "nonpayable",
  },
] as const;

// ============================================================
async function main() {
  const rpcUrl = process.env.RPC_URL || "";
  const privateKey = (process.env.PRIVATE_KEY || "") as `0x${string}`;
  const cctpContract = (process.env.CCTP_CONTRACT || "") as `0x${string}`;
  const chainId = parseInt(process.env.CHAIN_ID || "1");

  const destinationDomain = parseInt(process.env.DESTINATION_DOMAIN || "6");
  const mintRecipient = (process.env.MINT_RECIPIENT || "") as `0x${string}`;
  const burnToken = (process.env.SOURCE_USDC || "") as `0x${string}`;
  const amount = parseUnits(process.env.AMOUNT || "10", 6);

  if (!rpcUrl || !privateKey || !cctpContract || !mintRecipient || !burnToken) {
    console.error("Missing env vars: RPC_URL, PRIVATE_KEY, CCTP_CONTRACT, MINT_RECIPIENT, SOURCE_USDC");
    process.exit(1);
  }

  const chain = getChain(chainId);

  console.log("=".repeat(60));
  console.log("CCTP V2 — Send USDC Cross-Chain");
  console.log("=".repeat(60));
  console.log(`CCTP Contract  : ${cctpContract}`);
  console.log(`Destination    : Domain ${destinationDomain}`);
  console.log(`Recipient      : ${mintRecipient}`);
  console.log(`Amount         : ${process.env.AMOUNT || "10"} USDC`);
  console.log(`Burn Token     : ${burnToken}`);

  const publicClient = createPublicClient({ transport: http(rpcUrl), chain });
  const account = privateKeyToAccount(privateKey);
  const sender = account.address;

  // ========== 1. 余额 & 授权 ==========
  console.log(`\n[Wallet] ${sender}`);

  const [balance, allowance] = await Promise.all([
    publicClient.readContract({ address: burnToken, abi: USDC_ABI, functionName: "balanceOf", args: [sender] }),
    publicClient.readContract({ address: burnToken, abi: USDC_ABI, functionName: "allowance", args: [sender, cctpContract] }),
  ]);

  console.log(`USDC Balance   : ${Number(balance) / 1e6} USDC`);
  console.log(`Allowance      : ${Number(allowance) / 1e6} USDC`);

  if (balance < amount) {
    console.error(`[ERROR] Insufficient USDC. Need ${Number(amount) / 1e6}, have ${Number(balance) / 1e6}`);
    process.exit(1);
  }

  // ========== 2. 授权（如需要） ==========
  if (allowance < amount) {
    console.log("\n[Step 2] Approving CCTP...");
    const walletClient = createWalletClient({ account, transport: http(rpcUrl), chain });
    const hash = await walletClient.writeContract({
      address: burnToken,
      abi: USDC_ABI,
      functionName: "approve",
      args: [cctpContract, amount],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`  Approval TX   : ${receipt.status === "success" ? "SUCCESS" : "FAILED"}`);
  } else {
    console.log("\n[Step 2] Already approved.");
  }

  // ========== 3. 发送 depositForBurn ==========
  console.log("\n[Step 3] Sending depositForBurn...");
  const walletClient = createWalletClient({ account, transport: http(rpcUrl), chain });
  const sendHash = await walletClient.writeContract({
    address: cctpContract,
    abi: CCTP_ABI,
    functionName: "sendUSDC",
    args: [amount, destinationDomain, mintRecipient, burnToken],
  });

  console.log(`  TX Hash       : ${sendHash}`);
  const explorer = chain.blockExplorers?.default.url;
  if (explorer) console.log(`  Explorer      : ${explorer}/tx/${sendHash}`);

  const receipt = await publicClient.waitForTransactionReceipt({ hash: sendHash });
  console.log(`  Block         : ${receipt.blockNumber}`);
  console.log(`  Status        : ${receipt.status === "success" ? "SUCCESS" : "FAILED"}`);
  console.log(`  Gas Used      : ${receipt.gasUsed.toLocaleString()}`);

  if (receipt.status === "success") {
    console.log("\n[CCTP] Send initiated!");
    console.log("  Next: parse logs for messageHash, then run receiveAttestation.ts on destination chain.");
  } else {
    process.exit(1);
  }
}

main().catch((e) => {
  console.error("\n[ERROR]", e);
  process.exit(1);
});
