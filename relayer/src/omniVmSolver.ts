
import {
createPublicClient,
createWalletClient,
http,
Address,
Hex
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia, arbitrumSepolia } from "viem/chains";
import {
OMNI_VM_ABI,
getOmniChainById
} from "./omniVmConfig";
import {
BatchDispatchIntentMessage,
assertValidBatchIntent,
verifyOmniVmBatchSignature,
quoteOmniVmBatch
} from "./omniVmSdk";

// ============================================================================
// SOLVER CONFIGURATION & ENVIRONMENT SETUP
// ============================================================================

const SOLVER_PRIVATE_KEY = process.env.SOLVER_PRIVATE_KEY as Hex;
if (!SOLVER_PRIVATE_KEY) {
throw new Error("Missing SOLVER_PRIVATE_KEY environment variable.");
}

const solverAccount = privateKeyToAccount(SOLVER_PRIVATE_KEY);

// Example: Operating on Sepolia (Source) -> Arbitrum Sepolia (Destination)
const srcChainConfig = getOmniChainById(11155111)!; // Sepolia
const dstChainConfig = getOmniChainById(421614)!; // Arbitrum Sepolia

const publicClient = createPublicClient({
chain: sepolia,
transport: http(process.env.NEXT_PUBLIC_ETH_RPC_URL),
});

const walletClient = createWalletClient({
account: solverAccount,
chain: sepolia,
transport: http(process.env.NEXT_PUBLIC_ETH_RPC_URL),
});

// ============================================================================
// INTENT SOLVER PIPELINE
// ============================================================================

export interface SolverJobRequest {
intent: BatchDispatchIntentMessage;
signature: Hex;
}

/**
• Validates, verifies, quotes, and broadcasts a signed OmniVM cross-chain intent batch.
*/
export async function executeOmniVmIntent(job: SolverJobRequest): Promise<Hex> {
const { intent, signature } = job;

console.log("--------------------------------------------------");
console.log([Solver] Processing intent for sender: ${intent.sender}); console.log([Solver] Route: EID ${intent.srcEid} → EID ${intent.dstEid}); console.log([Solver] Instructions count: ${intent.instructions.length});
console.log("--------------------------------------------------");

// 1. Pre-flight invariant validation (checks zero addresses, sums, deadlines, max size)
try {
assertValidBatchIntent(intent);
console.log("✓ Step 1: Pre-flight intent invariants passed.");
} catch (err: any) {
throw new Error(Intent invariant validation failed: ${err.message}`);
}

// 2. Cryptographic signature verification (supports EOA + ERC-1271 Smart Wallets)
const verification = await verifyOmniVmBatchSignature({
chainId: srcChainConfig.chainId,
verifyingContract: srcChainConfig.omniVmAddress,
intent,
signature,
publicClient,
});

if (!verification.isValid) {
throw new Error(
InvalidIntentSignature: Signature verification failed for sender${intent.sender} (Recovered: latex
{verification.recoveredAddress})` ); } console.log(`✓ Step 2: Signature verified successfully! (Recovered/Wallet: 

{intent.sender})`);

// 3. Dynamic LayerZero V2 fee quoting
console.log("⏳ Step 3: Quoting LayerZero V2 messaging fee...");
const quoteResult = await quoteOmniVmBatch({
publicClient,
srcOmniVm: srcChainConfig.omniVmAddress,
dstOmniVmPeer: dstChainConfig.omniVmAddress,
endpointV2: srcChainConfig.endpointV2,
dstEid: intent.dstEid,
sender: intent.sender,
refundRecipient: intent.refundRecipient,
instructions: intent.instructions,
baseOptions: intent.options,
feeBufferBps: 200, // +2% safety buffer
});

console.log(✓ Step 3 Quote Received via [${quoteResult.source}]); console.log( - Required Native Fee: ${quoteResult.nativeFee.toString()} wei);
console.log(- Buffered msg.value: ${quoteResult.bufferedNativeFee.toString()} wei`);

// 4. Broadcast transaction to OmniVM.dispatchBatchWithSig on Source Chain
console.log("🚀 Step 4: Broadcasting dispatchBatchWithSig transaction...");

const txHash = await walletClient.writeContract({
address: srcChainConfig.omniVmAddress,
abi: OMNI_VM_ABI,
functionName: "dispatchBatchWithSig",
args: [
intent.sender,
intent.refundRecipient,
intent.dstEid,
intent.instructions,
intent.options,
intent.deadline,
signature,
 ],
value: quoteResult.bufferedNativeFee, // Pays LZ native fee + instruction native value
});

console.log(🎉 Success! Source Chain Transaction Hash:${txHash}); console.log(🔗 Track on Etherscan:  {txHash}`);

return txHash;
}

// ============================================================================
// LOCAL STANDALONE TEST RUNNER (Optional)
// ============================================================================
if (require.main === module) {
console.log("OmniVM Solver Daemon Initialized.");
console.log("Listening for incoming cross-chain dispatch intents...");
}
