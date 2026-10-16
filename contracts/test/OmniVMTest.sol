// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { OmniVM } from "../src/OmniVM.sol";
import { MessagingFee, MessagingReceipt, Origin } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import { OptionsBuilder } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// ============================================================================
// 1. MINIMAL LAYERZERO V2 ENDPOINT HARNESS (SELF-CONTAINED)
// ============================================================================

interface ILzReceiver {
function lzReceive(
Origin calldata _origin,
bytes32 _guid,
bytes calldata _message,
address _executor,
bytes calldata _extraData
) external payable;
}

struct MessagingParams {
uint32 dstEid;
bytes32 receiver;
bytes message;
bytes options;
bool payInLzToken;
}

/**
• @dev Simulates LayerZero V2 EndpointV2 for deterministic local Foundry testing.
• Parses Type 3 Executor lzReceive options to extract required destination
• msg.value and routes packets to remote MockEndpointV2 instances.
*/
contract MockEndpointV2 {
uint32 public immutable eid;
uint64 public nonce;
uint256 public constant BASE_MESSAGING_FEE = 0.001 ether;

mapping(address => address) public delegates;
mapping(uint32 => MockEndpointV2) public remoteEndpoints;

struct QueuedPacket {
Origin origin;
address dstOApp;
bytes32 guid;
bytes message;
uint256 lzReceiveValue;
bool delivered;
}

QueuedPacket[] public packetQueue;

constructor(uint32 _eid) {
eid = _eid;
}

function setDelegate(address _delegate) external {
delegates[msg.sender] = _delegate;
}

function wireRemoteEndpoint(uint32 _remoteEid, MockEndpointV2 _remote) external {
remoteEndpoints[_remoteEid] = _remote;
}

/**
* @dev Parses Type 3 Options (0x0003) and sums all Executor lzReceive (0x01)
* value fields, matching LayerZero V2's Executor options parser.
*/
function parseLzReceiveValue(bytes memory _options) public pure returns (uint256 totalValue) {
if (_options.length < 2) revert("InvalidOptionType");
uint16 optionType;
assembly {
optionType := shr(240, mload(add(_options, 32)))
}
if (optionType != 3) revert("InvalidOptionType");

uint256 cursor = 2;
while (cursor < _options.length) {
uint8 workerId = uint8(_options[cursor]);
cursor += 1;
uint16 optionLen;
assembly {
optionLen := shr(240, mload(add(add(_options, 32), cursor)))
}
cursor += 2;
uint8 optType = uint8(_options[cursor]);

// Worker 1 (Executor), Option 1 (lzReceive), length 33 (1 + 16 gas + 16 value)
if (workerId == 1 && optType == 1 && optionLen == 33) {
uint128 val;
uint256 valOffset = cursor + 1 + 16;
assembly {
val := shr(128, mload(add(add(_options, 32), valOffset)))
}
totalValue += uint256(val);
}
cursor += optionLen;
}
}

function quote(
MessagingParams calldata _params,
address /_sender/
) external pure returns (MessagingFee memory) {
uint256 lzReceiveVal = parseLzReceiveValue(_params.options);
return MessagingFee({
nativeFee: BASE_MESSAGING_FEE + lzReceiveVal,
lzTokenFee: 0
});
}

function send(
MessagingParams calldata _params,
address _refundAddress
) external payable returns (MessagingReceipt memory receipt) {
uint256 lzReceiveVal = parseLzReceiveValue(_params.options);
uint256 requiredFee = BASE_MESSAGING_FEE + lzReceiveVal;
require(msg.value >= requiredFee, "LZ_InsufficientFee");

nonce++;
bytes32 guid = keccak256(
abi.encodePacked(eid, msg.sender, _params.dstEid, _params.receiver, nonce)
);

MockEndpointV2 dstEndpoint = remoteEndpoints[_params.dstEid];
require(address(dstEndpoint) != address(0), "RemoteEndpointNotWired");

address dstOApp = address(uint160(uint256(_params.receiver)));
dstEndpoint.enqueuePacket(
Origin({
srcEid: eid,
sender: bytes32(uint256(uint160(msg.sender))),
nonce: nonce
}),
dstOApp,
guid,
_params.message,
lzReceiveVal
);

// Refund excess native fee to _refundAddress
uint256 excess = msg.value - requiredFee;
if (excess > 0) {
(bool ok, ) = _refundAddress.call{value: excess}("");
require(ok, "RefundFailed");
}

return MessagingReceipt({
guid: guid,
nonce: nonce,
fee: MessagingFee(requiredFee, 0)
});
}

function enqueuePacket(
Origin calldata _origin,
address _dstOApp,
bytes32 _guid,
bytes calldata _message,
uint256 _lzReceiveValue
) external {
packetQueue.push(
QueuedPacket({
origin: _origin,
dstOApp: _dstOApp,
guid: _guid,
message: _message,
lzReceiveValue: _lzReceiveValue,
delivered: false
})
);
}

function deliverNextPacket() external {
deliverNextPacketWithValueOverride(false, 0);
}

function deliverNextPacketWithValueOverride(bool _override, uint256 _customValue) public {
for (uint256 i = 0; i < packetQueue.length; i++) {
if (!packetQueue[i].delivered) {
packetQueue[i].delivered = true;
QueuedPacket memory pkt = packetQueue[i];
uint256 valToSend = _override ? _customValue : pkt.lzReceiveValue;

ILzReceiver(pkt.dstOApp).lzReceive{value: valToSend}(
pkt.origin,
pkt.guid,
pkt.message,
address(this),
""
);
return;
}
}
revert("NoPendingPackets");
}

receive() external payable {}
}

// ============================================================================
// 2. MOCK TARGET CONTRACTS (TRANSIENT CONTEXT, REENTRANCY, RETURN-BOMB, ERC1271)
// ============================================================================

/**
• @dev Omnichain-aware vault that authenticates callers via OmniVM.xMsgSender()
• and OmniVM.xMsgOrigin() from EIP-1153 transient storage.
*/
contract MockOmniVault {
OmniVM public immutable omniVM;

address public lastXSender;
uint32 public lastXOrigin;
uint256 public lastNumber;
mapping(uint32 => mapping(address => uint256)) public userDeposits;

error CustomVaultRevert(string reason, uint256 code);

constructor(OmniVM _omniVM) {
omniVM = _omniVM;
}

function depositAndRecord(uint256 _num) external payable {
address xSender = omniVM.xMsgSender();
uint32 xOrigin = omniVM.xMsgOrigin();

lastXSender = xSender;
lastXOrigin = xOrigin;
lastNumber = _num;
userDeposits[xOrigin][xSender] += msg.value;
}

function alwaysReverts() external pure {
revert CustomVaultRevert("VaultSlippageExceeded", 404);
}
}

/**
• @dev Malicious target that attempts cross-function reentrancy into OmniVM.
*/
contract MaliciousReentrantTarget {
OmniVM public immutable omniVM;

constructor(OmniVM _omniVM) {
omniVM = _omniVM;
}

function attemptReenterDispatch() external payable {
OmniVM.Instruction[] memory insts = new OmniVM.Instruction;
insts[0] = OmniVM.Instruction({
target: address(0xBEEF),
value: 0,
payload: ""
});
omniVM.dispatchBatch(30101, address(this), insts, hex"0003");
}
}

/**
• @dev Malicious refund recipient that allocates 2MB of memory on receive()
• to trigger a Return-Data Bomb / Out-Of-Gas panic if uncapped.
*/
contract ReturnBombRecipient {
fallback() external payable {
assembly {
// Return 2,000,000 bytes of memory to grief the caller if return data is copied
return(0, 2000000)
}
}
}

/**
• @dev Mock ERC-1271 Smart Contract Wallet controlled by an owner EOA.
*/
contract MockERC1271Wallet is IERC1271 {
address public immutable signer;

constructor(address _signer) {
signer = _signer;
}

function isValidSignature(
bytes32 _hash,
bytes memory _signature
) external view override returns (bytes4) {
(address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(_hash, _signature);
if (err == ECDSA.RecoverError.NoError && recovered == signer) {
return IERC1271.isValidSignature.selector;
}
return 0xffffffff;
}

receive() external payable {}
}

// ============================================================================
// 3. MAIN FOUNDRY TEST SUITE
// ============================================================================

contract OmniVMTest is Test {
using OptionsBuilder for bytes;

uint32 internal constant SRC_EID = 30101; // Ethereum
uint32 internal constant DST_EID = 30110; // Arbitrum

MockEndpointV2 internal srcEndpoint;
MockEndpointV2 internal dstEndpoint;

OmniVM internal srcOmniVM;
OmniVM internal dstOmniVM;

MockOmniVault internal dstVault;
MaliciousReentrantTarget internal maliciousReentrant;
ReturnBombRecipient internal returnBombRecipient;

uint256 internal alicePk = 0xA11CE;
address internal alice;
uint256 internal relayerPk = 0xB0B;
address internal relayer;
address internal owner = address(0xABCD);

bytes32 private constant DOMAIN_TYPEHASH =
keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

function setUp() public {
alice = vm.addr(alicePk);
relayer = vm.addr(relayerPk);

vm.deal(alice, 100 ether);
vm.deal(relayer, 100 ether);

// 1. Deploy Mock LayerZero V2 Endpoints & fund destination endpoint for lzReceive value drops
srcEndpoint = new MockEndpointV2(SRC_EID);
dstEndpoint = new MockEndpointV2(DST_EID);
vm.deal(address(dstEndpoint), 1000 ether);

srcEndpoint.wireRemoteEndpoint(DST_EID, dstEndpoint);
dstEndpoint.wireRemoteEndpoint(SRC_EID, srcEndpoint);

// 2. Deploy OmniVM instances on Source and Destination
srcOmniVM = new OmniVM(address(srcEndpoint), owner);
dstOmniVM = new OmniVM(address(dstEndpoint), owner);

// 3. Wire OApp peers bidirectionally
vm.startPrank(owner);
srcOmniVM.setPeer(DST_EID, bytes32(uint256(uint160(address(dstOmniVM)))));
dstOmniVM.setPeer(SRC_EID, bytes32(uint256(uint160(address(srcOmniVM)))));
vm.stopPrank();

// 4. Deploy test targets on Destination
dstVault = new MockOmniVault(dstOmniVM);
maliciousReentrant = new MaliciousReentrantTarget(dstOmniVM);
returnBombRecipient = new ReturnBombRecipient();
}

// ========================================================================
// A. TRANSIENT CONTEXT (xMsgSender / xMsgOrigin) & ATOMIC EXECUTION
// ========================================================================

function test_DispatchBatch_MountsAndClearsTransientContext() public {
// Pre-check: Transient storage starts zeroed
assertEq(dstOmniVM.xMsgSender(), address(0));
assertEq(dstOmniVM.xMsgOrigin(), 0);

OmniVM.Instruction[] memory insts = new OmniVM.Instruction;
insts[0] = OmniVM.Instruction({
target: address(dstVault),
value: 1.5 ether,
payload: abi.encodeCall(MockOmniVault.depositAndRecord, (42))
});
insts[1] = OmniVM.Instruction({
target: address(dstVault),
value: 0.5 ether,
payload: abi.encodeCall(MockOmniVault.depositAndRecord, (99))
});

bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0);

MessagingFee memory fee = srcOmniVM.quoteBatch(DST_EID, alice, insts, options, false);
assertEq(fee.nativeFee, 0.001 ether + 2.0 ether);

vm.prank(alice);
bytes32 guid = srcOmniVM.dispatchBatch{value: fee.nativeFee}(
DST_EID,
alice,
insts,
options
);
assertTrue(guid != bytes32(0));

// Deliver packet on destination chain
dstEndpoint.deliverNextPacket();

// 1. Verify target contract read the exact xMsgSender and xMsgOrigin from EIP-1153 transient storage
assertEq(dstVault.lastXSender(), alice);
assertEq(dstVault.lastXOrigin(), SRC_EID);
assertEq(dstVault.lastNumber(), 99);
assertEq(dstVault.userDeposits(SRC_EID, alice), 2.0 ether);

// 2. Verify transient storage was explicitly wiped after _lzReceive finished
assertEq(dstOmniVM.xMsgSender(), address(0));
assertEq(dstOmniVM.xMsgOrigin(), 0);
}

// ========================================================================
// B. ENDPOINT HIJACK & SELF-CALL SECURITY REVERTS
// ========================================================================

function test_RevertWhen_SourceInstructionTargetsSourceEndpoint() public {
OmniVM.Instruction[] memory insts = new OmniVM.Instruction;
// Attempt to call LayerZero EndpointV2.setDelegate(attacker)
insts[0] = OmniVM.Instruction({
target: address(srcEndpoint),
value: 0,
payload: abi.encodeCall(MockEndpointV2.setDelegate, (alice))
});

bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);

vm.prank(alice);
vm.expectRevert(
abi.encodeWithSelector(OmniVM.RestrictedTarget.selector, address(srcEndpoint))
);
srcOmniVM.dispatchBatch{value: 1 ether}(DST_EID, alice, insts, options);
}

function test_RevertWhen_DestinationInstructionHijacksDestinationEndpoint() public {
// Because srcEndpoint != dstEndpoint in this multi-endpoint setup, an attacker might
// bypass source-chain target checks by targeting address(dstEndpoint) in their payload.
// _lzReceive on the destination MUST catch and revert this!
address attacker = address(0xBAD);
OmniVM.Instruction[] memory insts = new OmniVM.Instruction;
insts[0] = OmniVM.Instruction({
target: address(dstEndpoint),
value: 0,
payload: abi.encodeCall(MockEndpointV2.setDelegate, (attacker))
});

bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
MessagingFee memory fee = srcOmniVM.quoteBatch(DST_EID, alice, insts, options, false);

vm.prank(alice);
srcOmniVM.dispatchBatch{value: fee.nativeFee}(DST_EID, alice, insts, options);

// Delivery on destination chain must revert with RestrictedTarget(dstEndpoint)
vm.expectRevert(
abi.encodeWithSelector(OmniVM.RestrictedTarget.selector, address(dstEndpoint))
);
dstEndpoint.deliverNextPacket();

// Confirm delegate was NOT changed to attacker
assertEq(dstEndpoint.delegates(address(dstOmniVM)), owner);
}

function test_RevertWhen_InstructionTargetsOmniVMSelf() public {
OmniVM.Instruction[] memory insts = new OmniVM.Instruction;
insts[0] = OmniVM.Instruction({
target: address(srcOmniVM),
value: 0,
payload: ""
});

bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);

vm.prank(alice);
vm.expectRevert(
abi.encodeWithSelector(OmniVM.RestrictedTarget.selector, address(srcOmniVM))
);
srcOmniVM.dispatchBatch{value: 1 ether}(DST_EID, alice, insts, options);
}

function test_RevertWhen_DestinationInstructionTargetsDestinationOmniVM() public {
OmniVM.Instruction[] memory insts = new OmniVM.Instruction;
insts[0] = OmniVM.Instruction({
target: address(dstOmniVM),
value: 0,
payload: ""
});

bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
MessagingFee memory fee = srcOmniVM.quoteBatch(DST_EID, alice, insts, options, false);

vm.prank(alice);
srcOmniVM.dispatchBatch{value: fee.nativeFee}(DST_EID, alice, insts, options);

vm.expectRevert(
abi.encodeWithSelector(OmniVM.RestrictedTarget.selector, address(dstOmniVM))
);
dstEndpoint.deliverNextPacket();
}

// ========================================================================
// C. EIP-712 SIGNATURES (dispatchBatchWithSig): EOA, ERC-1271 & REPLAYS
// ========================================================================

function _signBatchIntent(
uint256 _pk,
address _sender,
address _refundRecipient,
uint32 _dstEid,
OmniVM.Instruction[] memory _instructions,
bytes memory _options,
uint256 _nonce,
uint256 _deadline
) internal view returns (bytes memory sig, bytes32 digest) {
bytes32[] memory instHashes = new bytes32;
uint256 totalValue = 0;

for (uint256 i = 0; i < _instructions.length; i++) {
totalValue += _instructions[i].value;
instHashes[i] = keccak256(
abi.encode(
srcOmniVM.INSTRUCTION_TYPEHASH(),
_instructions[i].target,
_instructions[i].value,
keccak256(_instructions[i].payload)
)
);
}

bytes32 structHash = keccak256(
abi.encode(
srcOmniVM.BATCH_DISPATCH_INTENT_TYPEHASH(),
_sender,
_refundRecipient,
SRC_EID,
_dstEid,
keccak256(abi.encodePacked(instHashes)),
totalValue,
keccak256(_options),
_nonce,
_deadline
)
);

bytes32 domainSeparator = keccak256(
abi.encode(
DOMAIN_TYPEHASH,
keccak256(bytes("OmniVM")),
keccak256(bytes("1")),
block.chainid,
address(srcOmniVM)
)
);

digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
(uint8 v, bytes32 r, bytes32 s) = vm.sign(_pk, digest);
sig = abi.encodePacked(r, s, v);
}

function test_DispatchBatchWithSig_EOASignatureRelayedAndReplayBlocked() public {
OmniVM.Instruction[] memory insts = new OmniVM.Instruction;
insts[0] = OmniVM.Instruction({
target: address(dstVault),
value: 1 ether,
payload: abi.encodeCall(MockOmniVault.depositAndRecord, (777))
});

bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
uint256 currentNonce = srcOmniVM.nonces(alice);
uint256 deadline = block.timestamp + 30 minutes;

(bytes memory sig, ) = _signBatchIntent(
alicePk,
alice,
alice,
DST_EID,
insts,
options,
currentNonce,
deadline
);

MessagingFee memory fee = srcOmniVM.quoteBatch(DST_EID, alice, insts, options, false);

// Relayer submits the signed intent on Alice's behalf
vm.prank(relayer);
srcOmniVM.dispatchBatchWithSig{value: fee.nativeFee}(
alice,
alice,
DST_EID,
insts,
options,
deadline,
sig
);

// Nonce incremented to 1
assertEq(srcOmniVM.nonces(alice), 1);

// Deliver packet on destination and verify xMsgSender() is Alice (NOT relayer!)
dstEndpoint.deliverNextPacket();
assertEq(dstVault.lastXSender(), alice);
assertEq(dstVault.lastXOrigin(), SRC_EID);
assertEq(dstVault.lastNumber(), 777);
assertEq(dstVault.userDeposits(SRC_EID, alice), 1 ether);

// Replay attack with the same signature must revert because nonce is now 1
vm.prank(relayer);
vm.expectRevert(OmniVM.InvalidIntentSignature.selector);
srcOmniVM.dispatchBatchWithSig{value: fee.nativeFee}(
alice,
alice,
DST_EID,
insts,
options,
deadline,
sig
);
}

function test_DispatchBatchWithSig_ERC1271SmartAccountSignature() public {
MockERC1271Wallet smartWallet = new MockERC1271Wallet(alice);

OmniVM.Instruction[] memory insts = new OmniVM.Instruction;
insts[0] = OmniVM.Instruction({
target: address(dstVault),
value: 0.25 ether,
payload: abi.encodeCall(MockOmniVault.depositAndRecord, (1271))
});

bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
uint256 deadline = block.timestamp + 1 hours;

(bytes memory sig, ) = _signBatchIntent(
alicePk,
address(smartWallet),
address(smartWallet),
DST_EID,
insts,
options,
0,
deadline
);

MessagingFee memory fee = srcOmniVM.quoteBatch(
DST_EID,
address(smartWallet),
insts,
options,
false
);

vm.prank(relayer);
srcOmniVM.dispatchBatchWithSig{value: fee.nativeFee}(
address(smartWallet),
address(smartWallet),
DST_EID,
insts,
options,
deadline,
sig
);

dstEndpoint.deliverNextPacket();
assertEq(dstVault.lastXSender(), address(smartWallet));
assertEq(dstVault.lastNumber(), 1271);
}

function test_RevertWhen_SignatureExpired() public {
OmniVM.Instruction[] memory insts = new OmniVM.Instruction;
insts[0] = OmniVM.Instruction({
target: address(dstVault),
value: 0,
payload: abi.encodeCall(MockOmniVault.depositAndRecord, (1))
});

bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
uint256 expiredDeadline = block.timestamp - 1;

(bytes memory sig, ) = _signBatchIntent(
alicePk,
alice,
alice,
DST_EID,
insts,
options,
0,
expiredDeadline
);

vm.prank(relayer);
vm.expectRevert(
abi.encodeWithSelector(
OmniVM.SignatureExpired.selector,
expiredDeadline,
block.timestamp
)
);
srcOmniVM.dispatchBatchWithSig{value: 1 ether}(
alice,
alice,
DST_EID,
insts,
options,
expiredDeadline,
sig
);
}

// ========================================================================
// D. ATOMICITY, REENTRANCY, RETURN-BOMB & BOUNDS PROTECTION
// ========================================================================

function test_RevertWhen_SecondInstructionFails_RollsBackFirstInstruction() public {
OmniVM.Instruction[] memory insts = new OmniVM.Instruction;
// Instruction 1 succeeds and deposits 1 ETH
insts[0] = OmniVM.Instruction({
target: address(dstVault),
value: 1 ether,
payload: abi.encodeCall(MockOmniVault.depositAndRecord, (111))
});
// Instruction 2 reverts with CustomVaultRevert("VaultSlippageExceeded", 404)
insts[1] = OmniVM.Instruction({
target: address(dstVault),
value: 0,
payload: abi.encodeCall(MockOmniVault.alwaysReverts, ())
});

bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0);
MessagingFee memory fee = srcOmniVM.quoteBatch(DST_EID, alice, insts, options, false);

vm.prank(alice);
srcOmniVM.dispatchBatch{value: fee.nativeFee}(DST_EID, alice, insts, options);

// Assembly revert bubbling must preserve the exact custom error from Instruction #2
vm.expectRevert(
abi.encodeWithSelector(
MockOmniVault.CustomVaultRevert.selector,
"VaultSlippageExceeded",
404
)
);
dstEndpoint.deliverNextPacket();

// Instruction #1 state change must be completely rolled back
assertEq(dstVault.userDeposits(SRC_EID, alice), 0);
}

function test_RevertWhen_TargetAttemptsReentrancy() public {
OmniVM.Instruction[] memory insts = new OmniVM.Instruction;
insts[0] = OmniVM.Instruction({
target: address(maliciousReentrant),
value: 0,
payload: abi.encodeCall(MaliciousReentrantTarget.attemptReenterDispatch, ())
});

bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0);
MessagingFee memory fee = srcOmniVM.quoteBatch(DST_EID, alice, insts, options, false);

vm.prank(alice);
srcOmniVM.dispatchBatch{value: fee.nativeFee}(DST_EID, alice, insts, options);

// ReentrancyGuardTransient blocks re-entering dispatchBatch while inside _lzReceive
vm.expectRevert(
abi.encodeWithSignature("ReentrancyGuardReentrantCall()")
);
dstEndpoint.deliverNextPacket();
}

function test_RefundSurvivesReturnDataBomb() public {
OmniVM.Instruction[] memory insts = new OmniVM.Instruction;
insts[0] = OmniVM.Instruction({
target: address(dstVault),
value: 0.5 ether,
payload: abi.encodeCall(MockOmniVault.depositAndRecord, (55))
});

// Request 0.5 ETH for instruction + 0.5 ETH extra unspent value
bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(
250_000,
0.5 ether
);
MessagingFee memory fee = srcOmniVM.quoteBatch(
DST_EID,
address(returnBombRecipient),
insts,
options,
false
);

vm.prank(alice);
srcOmniVM.dispatchBatch{value: fee.nativeFee}(
DST_EID,
address(returnBombRecipient),
insts,
options
);

// Even though returnBombRecipient attempts a 2MB return-data bomb on refund,
// call(30000, refundRecipient, remainingValue, 0, 0, 0, 0) caps gas and copies 0 bytes,
// allowing the batch execution to succeed without reverting the Executor channel!
dstEndpoint.deliverNextPacket();
assertEq(dstVault.lastNumber(), 55);
assertEq(dstVault.userDeposits(SRC_EID, alice), 0.5 ether);
}

function test_RevertWhen_TotalValueExceedsUint128() public {
OmniVM.Instruction[] memory insts = new OmniVM.Instruction;
uint256 halfMax = uint256(type(uint128).max);
insts[0] = OmniVM.Instruction({
target: address(dstVault),
value: halfMax,
payload: ""
});
insts[1] = OmniVM.Instruction({
target: address(dstVault),
value: 1,
payload: ""
});

bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);

vm.prank(alice);
vm.expectRevert(
abi.encodeWithSelector(OmniVM.ValueExceedsUint128.selector, halfMax + 1)
);
srcOmniVM.dispatchBatch(DST_EID, alice, insts, options);
}
}
