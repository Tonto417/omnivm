Import {
Address,
Hex,
concatHex,
fallback,
http,
isAddress,
pad,
sliceHex,
toHex,
} from "viem";
import { createConfig } from "wagmi";
import {
mainnet,
arbitrum,
optimism,
base,
sepolia,
arbitrumSepolia,
} from "wagmi/chains";

// ============================================================================
// 1. WAGMI V2 + VIEM MULTI-CHAIN CONFIGURATION
// ============================================================================

const rpcTransport = (envUrl?: string) =>
envUrl ? fallback([http(envUrl), http()]) : http();

export const wagmiConfig = createConfig({
chains: [mainnet, arbitrum, optimism, base, sepolia, arbitrumSepolia],
ssr: true,
transports: {
[mainnet.id]: rpcTransport(process.env.NEXT_PUBLIC_ETH_RPC_URL),
[arbitrum.id]: rpcTransport(process.env.NEXT_PUBLIC_ARBITRUM_RPC_URL),
[optimism.id]: rpcTransport(process.env.NEXT_PUBLIC_OPTIMISM_RPC_URL),
[base.id]: rpcTransport(process.env.NEXT_PUBLIC_BASE_RPC_URL),
[sepolia.id]: rpcTransport(process.env.NEXT_PUBLIC_SEPOLIA_RPC_URL),
[arbitrumSepolia.id]: rpcTransport(
process.env.NEXT_PUBLIC_ARB_SEPOLIA_RPC_URL
),
},
});

declare module "wagmi" {
interface Register {
config: typeof wagmiConfig;
}
}

// ============================================================================
// 2. LAYERZERO V2 ENDPOINT & OMNIVM DEPLOYMENT REGISTRY
// ============================================================================

export interface OmniChainConfig {
chainId: number;
name: string;
shortName: string;
nativeSymbol: string;
lzEid: number;
endpointV2: Address;
omniVmAddress: Address;
blockExplorer: string;
}

export const SUPPORTED_CHAINS: readonly OmniChainConfig[] = [
{
chainId: 1,
name: "Ethereum Mainnet",
shortName: "Ethereum",
nativeSymbol: "ETH",
lzEid: 30101,
endpointV2: "0x1a44076050125825900e736c501f859c50fE728c",
omniVmAddress: "0x000000000000000000000000000000000000dEaD",
blockExplorer: "https://etherscan.io",
},
{
chainId: 42161,
name: "Arbitrum One",
shortName: "Arbitrum",
nativeSymbol: "ETH",
lzEid: 30110,
endpointV2: "0x1a44076050125825900e736c501f859c50fE728c",
omniVmAddress: "0x000000000000000000000000000000000000dEaD",
blockExplorer: "https://arbiscan.io",
},
{
chainId: 10,
name: "Optimism",
shortName: "Optimism",
nativeSymbol: "ETH",
lzEid: 30111,
endpointV2: "0x1a44076050125825900e736c501f859c50fE728c",
omniVmAddress: "0x000000000000000000000000000000000000dEaD",
blockExplorer: "https://optimistic.etherscan.io",
},
{
chainId: 8453,
name: "Base Mainnet",
shortName: "Base",
nativeSymbol: "ETH",
lzEid: 30184,
endpointV2: "0x1a44076050125825900e736c501f859c50fE728c",
omniVmAddress: "0x000000000000000000000000000000000000dEaD",
blockExplorer: "https://basescan.org",
},
{
chainId: 11155111,
name: "Sepolia Testnet",
shortName: "Sepolia",
nativeSymbol: "ETH",
lzEid: 40161,
endpointV2: "0x6EDCE65403992e310A62460808c4b910D972f10f",
omniVmAddress: "0x000000000000000000000000000000000000dEaD",
blockExplorer: "https://sepolia.etherscan.io",
},
{
chainId: 421614,
name: "Arbitrum Sepolia",
shortName: "Arb Sepolia",
nativeSymbol: "ETH",
lzEid: 40231,
endpointV2: "0x6EDCE65403992e310A62460808c4b910D972f10f",
omniVmAddress: "0x000000000000000000000000000000000000dEaD",
blockExplorer: "https://sepolia.arbiscan.io",
},
] as const;

export const MAX_INSTRUCTIONS = 32;
export const MAX_UINT128 = (1n << 128n) - 1n;

export function getOmniChainById(chainId: number): OmniChainConfig | undefined {
return SUPPORTED_CHAINS.find((c) => c.chainId === chainId);
}

export function getOmniChainByEid(lzEid: number): OmniChainConfig | undefined {
return SUPPORTED_CHAINS.find((c) => c.lzEid === lzEid);
}

export function addressToBytes32(addr: Address): Hex {
if (!isAddress(addr)) {
throw new Error(Invalid EVM address: ${addr}`);
}
return pad(addr, { size: 32 });
}

// ============================================================================
// 3. HARDENED OMNIVM & LAYERZERO V2 ENDPOINT ABIs
// ============================================================================

export const OMNI_VM_ABI = [
{
type: "function",
name: "dispatchBatch",
stateMutability: "payable",
inputs: [
{ name: "_dstEid", type: "uint32" },
{ name: "_refundRecipient", type: "address" },
{
name: "_instructions",
type: "tuple[]",
components: [
{ name: "target", type: "address" },
{ name: "value", type: "uint256" },
{ name: "payload", type: "bytes" },
 ],
},
{ name: "_options", type: "bytes" },
],
outputs: [{ name: "guid", type: "bytes32" }],
},
{
type: "function",
name: "dispatchBatchWithSig",
stateMutability: "payable",
inputs: [
{ name: "_sender", type: "address" },
{ name: "_refundRecipient", type: "address" },
{ name: "_dstEid", type: "uint32" },
{
name: "_instructions",
type: "tuple[]",
components: [
{ name: "target", type: "address" },
{ name: "value", type: "uint256" },
{ name: "payload", type: "bytes" },
 ],
},
{ name: "_options", type: "bytes" },
{ name: "_deadline", type: "uint256" },
{ name: "_signature", type: "bytes" },
],
outputs: [{ name: "guid", type: "bytes32" }],
},
{
type: "function",
name: "quoteBatch",
stateMutability: "view",
inputs: [
{ name: "_dstEid", type: "uint32" },
{ name: "_refundRecipient", type: "address" },
{
name: "_instructions",
type: "tuple[]",
components: [
{ name: "target", type: "address" },
{ name: "value", type: "uint256" },
{ name: "payload", type: "bytes" },
 ],
},
{ name: "_options", type: "bytes" },
{ name: "_payInLzToken", type: "bool" },
],
outputs: [
{
name: "fee",
type: "tuple",
components: [
{ name: "nativeFee", type: "uint256" },
{ name: "lzTokenFee", type: "uint256" },
 ],
},
],
},
{
type: "function",
name: "nonces",
stateMutability: "view",
inputs: [{ name: "owner", type: "address" }],
outputs: [{ name: "", type: "uint256" }],
},
{
type: "function",
name: "peers",
stateMutability: "view",
inputs: [{ name: "_eid", type: "uint32" }],
outputs: [{ name: "peer", type: "bytes32" }],
},
{
type: "function",
name: "xMsgSender",
stateMutability: "view",
inputs: [],
outputs: [{ name: "sender", type: "address" }],
},
{
type: "function",
name: "xMsgOrigin",
stateMutability: "view",
inputs: [],
outputs: [{ name: "origin", type: "uint32" }],
},
{
type: "function",
name: "MAX_INSTRUCTIONS",
stateMutability: "view",
inputs: [],
outputs: [{ name: "", type: "uint256" }],
},
{
type: "function",
name: "rescueStuckNative",
stateMutability: "nonpayable",
inputs: [],
outputs: [],
},
{
type: "event",
name: "BatchDispatched",
inputs: [
{ name: "dstEid", type: "uint32", indexed: true },
{ name: "guid", type: "bytes32", indexed: true },
{ name: "sender", type: "address", indexed: true },
{ name: "refundRecipient", type: "address", indexed: false },
{ name: "instructionCount", type: "uint256", indexed: false },
{ name: "totalNativeValue", type: "uint256", indexed: false },
 ],
},
{
type: "event",
name: "BatchExecuted",
inputs: [
{ name: "srcEid", type: "uint32", indexed: true },
{ name: "guid", type: "bytes32", indexed: true },
{ name: "originalSender", type: "address", indexed: true },
{ name: "instructionCount", type: "uint256", indexed: false },
 ],
},
{
type: "event",
name: "StuckNativeRescued",
inputs: [
{ name: "owner", type: "address", indexed: true },
{ name: "amount", type: "uint256", indexed: false },
 ],
},
{
type: "error",
name: "RestrictedTarget",
inputs: [{ name: "target", type: "address" }],
},
{
type: "error",
name: "InsufficientPayment",
inputs: [
{ name: "required", type: "uint256" },
{ name: "provided", type: "uint256" },
 ],
},
{
type: "error",
name: "InvalidBatchSize",
inputs: [
{ name: "count", type: "uint256" },
{ name: "max", type: "uint256" },
 ],
},
{
type: "error",
name: "ValueExceedsUint128",
inputs: [{ name: "value", type: "uint256" }],
},
{
type: "error",
name: "InsufficientMsgValue",
inputs: [
{ name: "required", type: "uint256" },
{ name: "remaining", type: "uint256" },
 ],
},
{ type: "error", name: "InvalidRefundRecipient", inputs: [] },
{
type: "error",
name: "SignatureExpired",
inputs: [
{ name: "deadline", type: "uint256" },
{ name: "currentTimestamp", type: "uint256" },
 ],
},
{ type: "error", name: "InvalidIntentSignature", inputs: [] },
{ type: "error", name: "TransferFailed", inputs: [] },
] as const;

export const LZ_ENDPOINT_V2_ABI = [
{
type: "function",
name: "quote",
stateMutability: "view",
inputs: [
{
name: "_params",
type: "tuple",
components: [
{ name: "dstEid", type: "uint32" },
{ name: "receiver", type: "bytes32" },
{ name: "message", type: "bytes" },
{ name: "options", type: "bytes" },
{ name: "payInLzToken", type: "bool" },
 ],
},
{ name: "_sender", type: "address" },
],
outputs: [
{
name: "fee",
type: "tuple",
components: [
{ name: "nativeFee", type: "uint256" },
{ name: "lzTokenFee", type: "uint256" },
 ],
},
],
},
] as const;

// ============================================================================
// 4. LAYERZERO V2 TYPE 3 OPTIONS BUILDER UTILITIES
// ============================================================================

const TYPE_3_HEADER = "0x0003" as Hex;
const WORKER_ID_EXECUTOR = "0x01" as Hex;
const OPTION_TYPE_LZRECEIVE = "0x01" as Hex;
const OPTION_TYPE_NATIVE_DROP = "0x02" as Hex;

function ensureType3Header(options: Hex): Hex {
if (!options || options === "0x") {
return TYPE_3_HEADER;
}
if (options.length < 6 || sliceHex(options, 0, 2) !== TYPE_3_HEADER) {
throw new Error(
Invalid LayerZero options header: expected Type 3 (0x0003), received${options.slice(
0,
6
)}`
);
}
return options;
}

/**
• Encodes LayerZero V2 Type 3 execution options (OptionsBuilder.newOptions()).
• Base option: addExecutorLzReceiveOption(gasLimit, lzReceiveValue)
*/
export function buildLzReceiveOptions(
gasLimit: bigint,
lzReceiveValue: bigint = 0n
): Hex {
if (gasLimit < 0n || gasLimit > MAX_UINT128) {
throw new Error("Gas limit exceeds uint128 bounds.");
}
if (lzReceiveValue < 0n || lzReceiveValue > MAX_UINT128) {
throw new Error("lzReceive value exceeds uint128 bounds.");
}

const gasHex = pad(toHex(gasLimit), { size: 16 });
if (lzReceiveValue === 0n) {
// 1 byte optionType + 16 bytes gas = 17 bytes (0x0011)
const optionLen = pad(toHex(17), { size: 2 });
return concatHex([
TYPE_3_HEADER,
WORKER_ID_EXECUTOR,
optionLen,
OPTION_TYPE_LZRECEIVE,
gasHex,
 ]);
} else {
// 1 byte optionType + 16 bytes gas + 16 bytes value = 33 bytes (0x0021)
const valHex = pad(toHex(lzReceiveValue), { size: 16 });
const optionLen = pad(toHex(33), { size: 2 });
return concatHex([
TYPE_3_HEADER,
WORKER_ID_EXECUTOR,
optionLen,
OPTION_TYPE_LZRECEIVE,
gasHex,
valHex,
 ]);
}
}

/**
• Mirrors the hardened OmniVM.sol finalOptions.addExecutorLzReceiveOption(0, uint128(totalInstValue))
• so EndpointV2.quote() on the frontend matches _quote() on-chain byte-for-byte.
*/
export function appendExecutorLzReceiveValueOption(
baseOptions: Hex,
totalInstValue: bigint
): Hex {
const normalizedBase = ensureType3Header(baseOptions);
if (totalInstValue <= 0n) return normalizedBase;
if (totalInstValue > MAX_UINT128) {
throw new Error("Total instruction native value exceeds uint128 max.");
}

// 1 byte optionType + 16 bytes gas (0) + 16 bytes value = 33 bytes (0x0021)
const optionLen = pad(toHex(33), { size: 2 });
const zeroGasHex = pad(toHex(0n), { size: 16 });
const valHex = pad(toHex(totalInstValue), { size: 16 });

return concatHex([
normalizedBase,
WORKER_ID_EXECUTOR,
optionLen,
OPTION_TYPE_LZRECEIVE,
zeroGasHex,
valHex,
 ]);
}

/**
• Encodes an additional LayerZero V2 Native Drop (OptionType = 0x02) if you ever want
• to air-drop native gas directly to a user's EOA alongside the batch execution.
*/
export function appendExecutorNativeDropOption(
baseOptions: Hex,
dropAmount: bigint,
receiverAddress: Address
): Hex {
const normalizedBase = ensureType3Header(baseOptions);
if (dropAmount <= 0n) return normalizedBase;
if (dropAmount > MAX_UINT128) {
throw new Error("Native drop amount exceeds uint128 max.");
}

const optionLen = pad(toHex(49), { size: 2 });
const amountHex = pad(toHex(dropAmount), { size: 16 });
const receiverBytes32 = addressToBytes32(receiverAddress);

return concatHex([
normalizedBase,
WORKER_ID_EXECUTOR,
optionLen,
OPTION_TYPE_NATIVE_DROP,
amountHex,
receiverBytes32,
 ]);
}
