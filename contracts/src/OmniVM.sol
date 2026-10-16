// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { OApp, MessagingFee, Origin } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import { MessagingReceipt } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppSender.sol";
import { OptionsBuilder } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/**
• @title OmniVM
• @notice Production-grade omnichain execution environment utilizing EIP-1153
• Transient Storage for context & reentrancy protection, atomic batch
• execution, EIP-712 structured intent signatures, and secure native
• value routing via LayerZero V2.
*/
contract OmniVM is OApp, ReentrancyGuardTransient, EIP712, Nonces {
using OptionsBuilder for bytes;

// --- Data Structures ---
struct Instruction {
address target;
uint256 value;
bytes payload;
}

// --- Constants & Limits ---
uint256 public constant MAX_INSTRUCTIONS = 32;
uint256 private constant REFUND_GAS_STIPEND = 30_000;

// --- Transient Storage Slots (EIP-1153 - Cryptographically Namespaced) ---
bytes32 private constant SENDER_SLOT = keccak256("omnivm.transient.sender");
bytes32 private constant ORIGIN_SLOT = keccak256("omnivm.transient.origin");

// --- EIP-712 Typehashes ---
bytes32 public constant INSTRUCTION_TYPEHASH = keccak256(
"Instruction(address target,uint256 value,bytes payload)"
);

bytes32 public constant BATCH_DISPATCH_INTENT_TYPEHASH = keccak256(
"BatchDispatchIntent(address sender,address refundRecipient,uint32 srcEid,uint32 dstEid,Instruction[] instructions,uint256 totalNativeValue,bytes options,uint256 nonce,uint256 deadline)Instruction(address target,uint256 value,bytes payload)"
);

// --- Events ---
event BatchDispatched(
uint32 indexed dstEid,
bytes32 indexed guid,
address indexed sender,
address refundRecipient,
uint256 instructionCount,
uint256 totalNativeValue
);
event BatchExecuted(
uint32 indexed srcEid,
bytes32 indexed guid,
address indexed originalSender,
uint256 instructionCount
);
event StuckNativeRescued(address indexed owner, uint256 amount);

// --- Errors ---
error RestrictedTarget(address target);
error InsufficientPayment(uint256 required, uint256 provided);
error InvalidBatchSize(uint256 count, uint256 max);
error ValueExceedsUint128(uint256 value);
error InsufficientMsgValue(uint256 required, uint256 remaining);
error InvalidRefundRecipient();
error SignatureExpired(uint256 deadline, uint256 currentTimestamp);
error InvalidIntentSignature();
error TransferFailed();

constructor(
address _endpoint,
address _owner
) OApp(_endpoint, _owner) EIP712("OmniVM", "1") {}

// ================================================================
// │ TRANSIENT CROSS-CHAIN CONTEXT │
// ================================================================

/**
* @notice Authenticates the original cross-chain user caller.
*/
function xMsgSender() external view returns (address sender) {
assembly {
sender := tload(SENDER_SLOT)
}
}

/**
* @notice Identifies the source chain EID of the current execution.
*/
function xMsgOrigin() external view returns (uint32 origin) {
assembly {
origin := tload(ORIGIN_SLOT)
}
}

// ================================================================
// │ QUOTING LAYER │
// ================================================================

/**
* @notice Quotes the exact LayerZero V2 MessagingFee for a batch.
*/
function quoteBatch(
uint32 _dstEid,
address _refundRecipient,
Instruction[] calldata _instructions,
bytes calldata _options,
bool _payInLzToken
) external view returns (MessagingFee memory fee) {
uint256 len = _instructions.length;
if (len == 0 || len > MAX_INSTRUCTIONS) {
revert InvalidBatchSize(len, MAX_INSTRUCTIONS);
}

uint256 totalInstValue = 0;
for (uint256 i = 0; i < len; ) {
totalInstValue += _instructions[i].value;
unchecked {
++i;
}
}

if (totalInstValue > type(uint128).max) {
revert ValueExceedsUint128(totalInstValue);
}

bytes memory message = abi.encode(msg.sender, _refundRecipient, _instructions);
bytes memory finalOptions = _options.length == 0
? OptionsBuilder.newOptions()
: _options;
if (totalInstValue > 0) {
finalOptions = finalOptions.addExecutorLzReceiveOption(0, uint128(totalInstValue));
}

return _quote(_dstEid, message, finalOptions, _payInLzToken);
}

// ================================================================
// │ DISPATCH LAYER │
// ================================================================

/**
* @notice Dispatches an atomic batch of instructions directly as msg.sender.
*/
function dispatchBatch(
uint32 _dstEid,
address _refundRecipient,
Instruction[] calldata _instructions,
bytes calldata _options
) external payable nonReentrant returns (bytes32 guid) {
return _validateAndDispatch(msg.sender, _refundRecipient, _dstEid, _instructions, _options);
}

/**
* @notice Dispatches an atomic batch on behalf of a user using an EIP-712 structured intent signature.
*/
function dispatchBatchWithSig(
address _sender,
address _refundRecipient,
uint32 _dstEid,
Instruction[] calldata _instructions,
bytes calldata _options,
uint256 _deadline,
bytes calldata _signature
) external payable nonReentrant returns (bytes32 guid) {
if (block.timestamp > _deadline) {
revert SignatureExpired(_deadline, block.timestamp);
}

uint256 len = _instructions.length;
if (len == 0 || len > MAX_INSTRUCTIONS) {
revert InvalidBatchSize(len, MAX_INSTRUCTIONS);
}

bytes32[] memory instHashes = new bytes32;
uint256 totalInstValue = 0;

for (uint256 i = 0; i < len; ) {
Instruction calldata inst = _instructions[i];
totalInstValue += inst.value;
instHashes[i] = keccak256(
abi.encode(
INSTRUCTION_TYPEHASH,
inst.target,
inst.value,
keccak256(inst.payload)
)
);
unchecked {
++i;
}
}

uint256 currentNonce = _useNonce(_sender);

bytes32 structHash = keccak256(
abi.encode(
BATCH_DISPATCH_INTENT_TYPEHASH,
_sender,
_refundRecipient,
endpoint.eid(),
_dstEid,
keccak256(abi.encodePacked(instHashes)),
totalInstValue,
keccak256(_options),
currentNonce,
_deadline
)
);

bytes32 digest = _hashTypedDataV4(structHash);
if (!SignatureChecker.isValidSignatureNow(_sender, digest, _signature)) {
revert InvalidIntentSignature();
}

return _validateAndDispatch(_sender, _refundRecipient, _dstEid, _instructions, _options);
}

function _validateAndDispatch(
address _sender,
address _refundRecipient,
uint32 _dstEid,
Instruction[] calldata _instructions,
bytes calldata _options
) internal returns (bytes32 guid) {
uint256 len = _instructions.length;
if (len == 0 || len > MAX_INSTRUCTIONS) {
revert InvalidBatchSize(len, MAX_INSTRUCTIONS);
}
if (_refundRecipient == address(0)) {
revert InvalidRefundRecipient();
}

uint256 totalInstValue = 0;
address lzEndpoint = address(endpoint);

for (uint256 i = 0; i < len; ) {
address target = _instructions[i].target;
if (target == address(this) || target == lzEndpoint || target == address(0)) {
revert RestrictedTarget(target);
}
totalInstValue += _instructions[i].value;
unchecked {
++i;
}
}

if (totalInstValue > type(uint128).max) {
revert ValueExceedsUint128(totalInstValue);
}

bytes memory message = abi.encode(_sender, _refundRecipient, _instructions);

bytes memory finalOptions = _options.length == 0
? OptionsBuilder.newOptions()
: _options;
if (totalInstValue > 0) {
finalOptions = finalOptions.addExecutorLzReceiveOption(0, uint128(totalInstValue));
}

MessagingFee memory fee = _quote(_dstEid, message, finalOptions, false);
if (msg.value < fee.nativeFee) {
revert InsufficientPayment(fee.nativeFee, msg.value);
}

MessagingReceipt memory receipt = _lzSend(
_dstEid,
message,
finalOptions,
MessagingFee(msg.value, 0),
payable(msg.sender)
);

emit BatchDispatched(_dstEid, receipt.guid, _sender, _refundRecipient, len, totalInstValue);
return receipt.guid;
}

// ================================================================
// │ EXECUTION LAYER │
// ================================================================

/**
* @notice Executes the batch atomically on the destination chain.
/
function _lzReceive(
Origin calldata _origin,
bytes32 _guid,
bytes calldata _message,
address /_executor*/,
bytes calldata /_extraData/
) internal override nonReentrant {
(
address originalSender,
address refundRecipient,
Instruction[] memory instructions
) = abi.decode(_message, (address, address, Instruction[]));

uint32 srcEid = _origin.srcEid;

// Mount the Transient Context securely
assembly {
tstore(SENDER_SLOT, originalSender)
tstore(ORIGIN_SLOT, srcEid)
}

uint256 remainingValue = msg.value;
uint256 len = instructions.length;
address lzEndpoint = address(endpoint);

for (uint256 i = 0; i < len; ) {
Instruction memory inst = instructions[i];

if (inst.target == address(this) || inst.target == lzEndpoint || inst.target == address(0)) {
revert RestrictedTarget(inst.target);
}

if (inst.value > 0) {
if (remainingValue < inst.value) {
revert InsufficientMsgValue(inst.value, remainingValue);
}
unchecked {
remainingValue -= inst.value;
}
}

(bool success, bytes memory returnData) = inst.target.call{value: inst.value}(inst.payload);

if (!success) {
assembly {
revert(add(returnData, 32), mload(returnData))
}
}
unchecked {
++i;
}
}

// Clean up transient context explicitly on success
assembly {
tstore(SENDER_SLOT, 0)
tstore(ORIGIN_SLOT, 0)
}

emit BatchExecuted(srcEid, _guid, originalSender, len);

// Refund any unspent msg.value safely (capped gas + zero return-data copy to prevent return-bombs)
if (remainingValue > 0 && refundRecipient != address(0)) {
uint256 stipend = REFUND_GAS_STIPEND;
assembly {
pop(call(stipend, refundRecipient, remainingValue, 0, 0, 0, 0))
}
}
}

// ================================================================
// │ ADMIN / RESCUE │
// ================================================================

/**
* @notice Emergency function to rescue any trapped native tokens in the contract.
*/
function rescueStuckNative() external onlyOwner {
uint256 balance = address(this).balance;
if (balance == 0) revert TransferFailed();
(bool success, ) = owner().call{value: balance}("");
if (!success) revert TransferFailed();
emit StuckNativeRescued(owner(), balance);
}

/**
* @notice Fallback to accept native tokens.
*/
receive() external payable {}
}
