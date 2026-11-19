// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../contracts/AgentTaskEscrow.sol";

/// @notice Minimal stand-in for the Agent ID ERC-721 (balanceOf only).
///         Etched onto the real Agent ID address in setUp via vm.etch.
contract MockAgentID {
    mapping(address => uint256) public balanceOf;

    function setHolder(address account, bool holds) external {
        balanceOf[account] = holds ? 1 : 0;
    }
}

/// @notice Malicious worker: tries to re-enter approveWork from receive().
///         Swallows the inner call result so the outer payment can proceed;
///         the drain attempt itself must fail (mutex + status already set).
contract ReentrantWorker {
    AgentTaskEscrow public escrow;
    uint256 public taskId;

    constructor(AgentTaskEscrow _escrow) {
        escrow = _escrow;
    }

    function setTask(uint256 _taskId) external {
        taskId = _taskId;
    }

    function accept(uint256 id) external {
        escrow.acceptTask(id);
    }

    function submit(uint256 id, string calldata proof) external {
        escrow.submitWork(id, proof);
    }

    receive() external payable {
        // Reentrancy attempt: try to approve (and get paid) again.
        // The inner call must revert (nonReentrant + status Completed).
        (bool ok, ) = address(escrow).call(
            abi.encodeWithSignature("approveWork(uint256)", taskId)
        );
        ok; // swallowed on purpose: we only care the drain fails
    }
}

/// @notice Stand-in for an address whose receive() reverts (e.g. a contract
///         with no payable fallback). The revert is toggleable so the test
///         can prove queued funds are later withdrawable once the recipient
///         can receive again.
contract RevertingRecipient {
    AgentTaskEscrow public escrow;
    bool public reverting = true;

    constructor(AgentTaskEscrow _escrow) {
        escrow = _escrow;
    }

    function setReverting(bool v) external {
        reverting = v;
    }

    function post(uint256 deadline) external payable returns (uint256 id) {
        id = escrow.postTask{value: msg.value}("t", "d", deadline);
    }

    function accept(uint256 id) external {
        escrow.acceptTask(id);
    }

    function submit(uint256 id, string calldata proof) external {
        escrow.submitWork(id, proof);
    }

    function claimTimeout(uint256 id) external {
        escrow.claimTimeout(id);
    }

    function cancel(uint256 id) external {
        escrow.cancelTask(id);
    }

    function withdraw() external {
        escrow.withdraw();
    }

    receive() external payable {
        require(!reverting, "RevertingRecipient: cannot receive");
    }
}

contract AgentTaskEscrowTest is Test {
    AgentTaskEscrow public escrow;
    MockAgentID public mockId;

    address public poster = makeAddr("poster");
    address public worker = makeAddr("worker");
    address public stranger = makeAddr("stranger");

    uint256 constant REWARD = 1 ether;
    uint256 constant START = 1_000_000;

    function setUp() public {
        vm.warp(START);
        escrow = new AgentTaskEscrow();
        mockId = new MockAgentID();
        // Etch the mock onto the real Agent ID contract address.
        vm.etch(address(escrow.AGENT_ID()), address(mockId).code);
        MockAgentID(address(escrow.AGENT_ID())).setHolder(worker, true);
        MockAgentID(address(escrow.AGENT_ID())).setHolder(stranger, false);

        vm.deal(poster, 10 ether);
        vm.deal(worker, 10 ether);
        vm.deal(stranger, 10 ether);
    }

    function _post(uint256 reward, uint256 deadline) internal returns (uint256 id) {
        vm.prank(poster);
        id = escrow.postTask{value: reward}("Fix the landing page", "Ship a PR", deadline);
    }

    function _postDefault() internal returns (uint256 id) {
        return _post(REWARD, START + 7 days);
    }

    function _accept(uint256 id, address who) internal {
        vm.prank(who);
        escrow.acceptTask(id);
    }

    function _submit(uint256 id, address who) internal {
        vm.prank(who);
        escrow.submitWork(id, "https://example.com/pr/1");
    }

    // ---- happy path ----

    function testHappyPath() public {
        uint256 workerBefore = worker.balance;
        uint256 id = _postDefault();
        _accept(id, worker);
        _submit(id, worker);

        vm.prank(poster);
        escrow.approveWork(id);

        assertEq(worker.balance, workerBefore + REWARD, "worker must be paid exactly");
        assertEq(address(escrow).balance, 0, "escrow must be empty");
        assertEq(
            uint256(escrow.getTask(id).status),
            uint256(AgentTaskEscrow.Status.Completed)
        );
    }

    // ---- accept gates ----

    function testNonHolderCannotAccept() public {
        uint256 id = _postDefault();
        vm.prank(stranger);
        vm.expectRevert("AgentTask: caller holds no Agent ID");
        escrow.acceptTask(id);
    }

    function testPosterCannotAcceptOwnTask() public {
        // Poster is not a holder here; make them one so the holder gate passes
        // and the poster gate is the one that reverts.
        MockAgentID(address(escrow.AGENT_ID())).setHolder(poster, true);
        uint256 id = _postDefault();
        vm.prank(poster);
        vm.expectRevert("AgentTask: poster cannot accept own task");
        escrow.acceptTask(id);
    }

    function testDoubleAcceptBlocked() public {
        uint256 id = _postDefault();
        _accept(id, worker);
        MockAgentID(address(escrow.AGENT_ID())).setHolder(stranger, true);
        vm.prank(stranger);
        vm.expectRevert("AgentTask: task not open");
        escrow.acceptTask(id);
    }

    function testAcceptAfterDeadlineBlocked() public {
        uint256 id = _postDefault();
        vm.warp(START + 7 days); // exactly at deadline
        vm.prank(worker);
        vm.expectRevert("AgentTask: deadline passed");
        escrow.acceptTask(id);
    }

    // ---- reject / resubmit ----

    function testRejectResubmitApprove() public {
        uint256 workerBefore = worker.balance;
        uint256 id = _postDefault();
        _accept(id, worker);
        _submit(id, worker);

        vm.prank(poster);
        escrow.rejectWork(id);
        assertEq(
            uint256(escrow.getTask(id).status),
            uint256(AgentTaskEscrow.Status.Accepted)
        );

        _submit(id, worker);
        vm.prank(poster);
        escrow.approveWork(id);

        assertEq(worker.balance, workerBefore + REWARD);
        assertEq(address(escrow).balance, 0);
    }

    // ---- cancel ----

    function testCancelRefundsPoster() public {
        uint256 posterBefore = poster.balance;
        uint256 id = _postDefault();

        vm.prank(poster);
        escrow.cancelTask(id);

        assertEq(poster.balance, posterBefore, "poster must be refunded exactly");
        assertEq(address(escrow).balance, 0);
        assertEq(
            uint256(escrow.getTask(id).status),
            uint256(AgentTaskEscrow.Status.Cancelled)
        );
    }

    function testCancelAfterAcceptBlocked() public {
        uint256 id = _postDefault();
        _accept(id, worker);
        vm.prank(poster);
        vm.expectRevert("AgentTask: only open tasks can be cancelled");
        escrow.cancelTask(id);
    }

    // ---- timeouts ----

    function testTimeoutPosterReclaims() public {
        uint256 posterBefore = poster.balance;
        uint256 id = _postDefault();
        _accept(id, worker);

        vm.warp(START + 7 days + 1); // past deadline, no submission
        vm.prank(poster);
        escrow.claimTimeout(id);

        assertEq(poster.balance, posterBefore, "poster must be refunded exactly");
        assertEq(address(escrow).balance, 0);
        assertEq(
            uint256(escrow.getTask(id).status),
            uint256(AgentTaskEscrow.Status.Expired)
        );
    }

    function testTimeoutWorkerClaimsAfterSilence() public {
        uint256 workerBefore = worker.balance;
        uint256 id = _postDefault();
        _accept(id, worker);
        _submit(id, worker);

        // Poster silent for the full 3-day review window + 1s.
        vm.warp(START + 3 days + 1);
        vm.prank(worker);
        escrow.claimTimeout(id);

        assertEq(worker.balance, workerBefore + REWARD);
        assertEq(address(escrow).balance, 0);
        assertEq(
            uint256(escrow.getTask(id).status),
            uint256(AgentTaskEscrow.Status.Completed)
        );
    }

    function testTimeoutTooEarlyReverts() public {
        uint256 id = _postDefault();
        _accept(id, worker);

        vm.prank(poster);
        vm.expectRevert("AgentTask: deadline not passed");
        escrow.claimTimeout(id);

        _submit(id, worker);
        vm.warp(START + 3 days); // exactly at window end, not over
        vm.prank(worker);
        vm.expectRevert("AgentTask: review window not over");
        escrow.claimTimeout(id);
    }

    // ---- reentrancy ----

    function testReentrancyOnApproveFailsToDrain() public {
        ReentrantWorker attacker = new ReentrantWorker(escrow);
        MockAgentID(address(escrow.AGENT_ID())).setHolder(address(attacker), true);
        vm.deal(address(attacker), 1 ether);

        uint256 id = _postDefault();
        attacker.setTask(id);
        attacker.accept(id);
        attacker.submit(id, "https://example.com/pr/evil");

        uint256 attackerBefore = address(attacker).balance;
        vm.prank(poster);
        escrow.approveWork(id);

        // Exactly one payment: the reentrant inner approveWork reverted.
        assertEq(
            address(attacker).balance,
            attackerBefore + REWARD,
            "attacker must receive exactly one reward"
        );
        assertEq(address(escrow).balance, 0, "escrow must be empty, nothing drained");
        assertEq(
            uint256(escrow.getTask(id).status),
            uint256(AgentTaskEscrow.Status.Completed)
        );
    }

    // ---- pull-payment fallback ----

    function testApproveToRevertingWorkerQueuesPayment() public {
        RevertingRecipient badWorker = new RevertingRecipient(escrow);
        MockAgentID(address(escrow.AGENT_ID())).setHolder(address(badWorker), true);

        uint256 id = _postDefault();
        badWorker.accept(id);
        badWorker.submit(id, "https://example.com/pr/1");

        vm.prank(poster);
        escrow.approveWork(id); // must NOT revert

        assertEq(
            uint256(escrow.getTask(id).status),
            uint256(AgentTaskEscrow.Status.Completed),
            "task must still complete"
        );
        assertEq(
            escrow.pendingWithdrawal(address(badWorker)),
            REWARD,
            "reward must be queued for pull"
        );
        assertEq(address(escrow).balance, REWARD, "escrow still holds the queued reward");
        assertEq(address(badWorker).balance, 0, "worker received nothing yet");

        // Once the recipient can receive again, the queued funds pull out.
        badWorker.setReverting(false);
        badWorker.withdraw();

        assertEq(address(badWorker).balance, REWARD, "worker must receive the reward");
        assertEq(escrow.pendingWithdrawal(address(badWorker)), 0);
        assertEq(address(escrow).balance, 0);
    }

    function testTimeoutClaimToRevertingWorkerQueuesPayment() public {
        RevertingRecipient badWorker = new RevertingRecipient(escrow);
        MockAgentID(address(escrow.AGENT_ID())).setHolder(address(badWorker), true);

        uint256 id = _postDefault();
        badWorker.accept(id);
        badWorker.submit(id, "https://example.com/pr/1");

        vm.warp(START + 3 days + 1); // poster silent past the review window
        badWorker.claimTimeout(id); // must NOT revert

        assertEq(
            uint256(escrow.getTask(id).status),
            uint256(AgentTaskEscrow.Status.Completed),
            "task must still complete"
        );
        assertEq(escrow.pendingWithdrawal(address(badWorker)), REWARD);
        assertEq(address(escrow).balance, REWARD);

        badWorker.setReverting(false);
        badWorker.withdraw();
        assertEq(address(badWorker).balance, REWARD);
        assertEq(address(escrow).balance, 0);
    }

    function testWithdrawZeroReverts() public {
        vm.prank(stranger);
        vm.expectRevert("AgentTask: nothing to withdraw");
        escrow.withdraw();
    }

    function testDoubleWithdrawBlocked() public {
        RevertingRecipient badWorker = new RevertingRecipient(escrow);
        MockAgentID(address(escrow.AGENT_ID())).setHolder(address(badWorker), true);

        uint256 id = _postDefault();
        badWorker.accept(id);
        badWorker.submit(id, "https://example.com/pr/1");
        vm.prank(poster);
        escrow.approveWork(id);

        badWorker.setReverting(false);
        badWorker.withdraw();
        assertEq(address(badWorker).balance, REWARD);

        // Second pull must fail: balance was zeroed before the first payout.
        vm.expectRevert("AgentTask: nothing to withdraw");
        badWorker.withdraw();
    }

    function testCancelToRevertingPosterQueuesRefund() public {
        RevertingRecipient badPoster = new RevertingRecipient(escrow);
        vm.deal(address(badPoster), 10 ether);
        vm.deal(address(this), 10 ether); // this contract funds the post() call

        uint256 id = badPoster.post{value: REWARD}(START + 7 days);
        badPoster.cancel(id); // must NOT revert

        assertEq(
            uint256(escrow.getTask(id).status),
            uint256(AgentTaskEscrow.Status.Cancelled),
            "task must still cancel"
        );
        assertEq(
            escrow.pendingWithdrawal(address(badPoster)),
            REWARD,
            "refund must be queued for pull"
        );
        assertEq(address(escrow).balance, REWARD);

        badPoster.setReverting(false);
        badPoster.withdraw();
        // Poster started with 10 ether (its own funds untouched: the test
        // contract funded the post), plus the 1 ether refund pulled back.
        assertEq(address(badPoster).balance, 11 ether);
        assertEq(address(escrow).balance, 0);
    }

    // ---- post gates ----

    function testZeroValuePostReverts() public {
        vm.prank(poster);
        vm.expectRevert("AgentTask: reward must be > 0");
        escrow.postTask{value: 0}("t", "d", START + 1 days);
    }

    function testPastDeadlineReverts() public {
        vm.prank(poster);
        vm.expectRevert("AgentTask: deadline must be in future");
        escrow.postTask{value: REWARD}("t", "d", START);
    }

    function testTooFarDeadlineReverts() public {
        vm.prank(poster);
        vm.expectRevert("AgentTask: deadline too far (> 30 days)");
        escrow.postTask{value: REWARD}("t", "d", START + 30 days + 1);
    }

    function testThirtyDayDeadlineAllowed() public {
        uint256 id = _post(REWARD, START + 30 days);
        assertEq(escrow.getTask(id).deadline, START + 30 days);
    }

    // ---- other role gates ----

    function testNonPosterCannotApprove() public {
        uint256 id = _postDefault();
        _accept(id, worker);
        _submit(id, worker);
        vm.prank(stranger);
        vm.expectRevert("AgentTask: only the poster can approve");
        escrow.approveWork(id);
    }

    function testNonWorkerCannotSubmit() public {
        uint256 id = _postDefault();
        _accept(id, worker);
        vm.prank(stranger);
        vm.expectRevert("AgentTask: only the worker can submit");
        escrow.submitWork(id, "fake");
    }

    function testApproveBeforeSubmitReverts() public {
        uint256 id = _postDefault();
        _accept(id, worker);
        vm.prank(poster);
        vm.expectRevert("AgentTask: work not submitted");
        escrow.approveWork(id);
    }

    function testGetTaskNonexistentReverts() public {
        vm.expectRevert("AgentTask: task does not exist");
        escrow.getTask(999);
    }

    function testIsAgentHolder() public view {
        assertTrue(escrow.isAgentHolder(worker));
        assertFalse(escrow.isAgentHolder(stranger));
    }
}
