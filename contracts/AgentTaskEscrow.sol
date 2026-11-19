// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title AgentTaskEscrow
/// @notice Microtask escrow board for Binance Agent ID holders.
///         Anyone can post a task with BNB locked in escrow. Only Agent ID
///         holders can accept and do the work. Payment releases on poster
///         approval; timeouts protect both sides.
/// @dev Immutable by design: no owner, no pause, no upgrade, no fees.
///      All BNB flows are poster -> worker (on approval / worker timeout
///      claim) or refund -> poster (cancel / poster timeout reclaim) only.
///      Built for the Binance Agent ID Hackathon (Nov-Dec 2026).
interface IAgentID {
    function balanceOf(address account) external view returns (uint256);
}

contract AgentTaskEscrow {
    IAgentID public constant AGENT_ID =
        IAgentID(0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F);

    /// @notice How long the poster has to approve/reject submitted work
    ///         before the worker can claim the reward (3 days).
    uint256 public constant REVIEW_WINDOW = 3 days;

    /// @notice Maximum task length from posting (30 days).
    uint256 public constant MAX_DURATION = 30 days;

    enum Status {
        Open, // posted, no worker yet
        Accepted, // worker accepted, work not submitted
        Submitted, // work submitted, awaiting poster review
        Completed, // reward paid to worker
        Cancelled, // poster cancelled while Open, reward refunded
        Expired // deadline passed with no submission, reward refunded
    }

    struct Task {
        uint256 id;
        address poster;
        address worker;
        string title;
        string description;
        uint256 reward;
        uint256 deadline;
        uint256 submittedAt;
        string proof;
        Status status;
    }

    uint256 public taskCount;
    mapping(uint256 => Task) private _tasks;

    /// @notice BNB queued for pull withdrawal when a push payment fails
    ///         (e.g. the recipient cannot receive BNB). Funds never lock:
    ///         the recipient can always pull the amount later via withdraw().
    mapping(address => uint256) public pendingWithdrawals;

    // Hand-rolled reentrancy guard (no external imports).
    bool private _locked;

    modifier nonReentrant() {
        require(!_locked, "AgentTask: reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    event TaskPosted(
        uint256 indexed id,
        address indexed poster,
        uint256 reward,
        uint256 deadline
    );
    event TaskAccepted(uint256 indexed id, address indexed worker);
    event WorkSubmitted(uint256 indexed id, address indexed worker);
    event WorkApproved(uint256 indexed id, address indexed worker, uint256 reward);
    event WorkRejected(uint256 indexed id, address indexed worker);
    event TaskCancelled(uint256 indexed id, address indexed poster);
    event TaskExpired(uint256 indexed id, address indexed poster);
    event PaymentReleased(uint256 indexed id, address indexed to, uint256 amount);
    event Refunded(uint256 indexed id, address indexed to, uint256 amount);
    event PaymentQueued(uint256 indexed id, address indexed to, uint256 amount);
    event RefundQueued(uint256 indexed id, address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    /// @notice True if the address holds an Agent ID (balanceOf > 0).
    function isAgentHolder(address account) public view returns (bool) {
        return AGENT_ID.balanceOf(account) > 0;
    }

    /// @notice Post a task, locking msg.value as the escrowed reward.
    function postTask(
        string calldata title,
        string calldata description,
        uint256 deadline
    ) external payable returns (uint256 id) {
        require(msg.value > 0, "AgentTask: reward must be > 0");
        require(deadline > block.timestamp, "AgentTask: deadline must be in future");
        require(
            deadline <= block.timestamp + MAX_DURATION,
            "AgentTask: deadline too far (> 30 days)"
        );

        id = taskCount;
        taskCount++;

        _tasks[id] = Task({
            id: id,
            poster: msg.sender,
            worker: address(0),
            title: title,
            description: description,
            reward: msg.value,
            deadline: deadline,
            submittedAt: 0,
            proof: "",
            status: Status.Open
        });

        emit TaskPosted(id, msg.sender, msg.value, deadline);
    }

    /// @notice Accept an open task. Only Agent ID holders, never the poster.
    function acceptTask(uint256 id) external {
        Task storage task = _tasks[id];
        require(task.status == Status.Open, "AgentTask: task not open");
        require(msg.sender != task.poster, "AgentTask: poster cannot accept own task");
        require(isAgentHolder(msg.sender), "AgentTask: caller holds no Agent ID");
        require(block.timestamp < task.deadline, "AgentTask: deadline passed");

        task.worker = msg.sender;
        task.status = Status.Accepted;
        emit TaskAccepted(id, msg.sender);
    }

    /// @notice Submit completed work (proof text or URL). Worker only, before deadline.
    function submitWork(uint256 id, string calldata proof) external {
        Task storage task = _tasks[id];
        require(task.status == Status.Accepted, "AgentTask: task not accepted");
        require(msg.sender == task.worker, "AgentTask: only the worker can submit");
        require(block.timestamp < task.deadline, "AgentTask: deadline passed");

        task.proof = proof;
        task.submittedAt = block.timestamp;
        task.status = Status.Submitted;
        emit WorkSubmitted(id, msg.sender);
    }

    /// @notice Approve submitted work and release the reward to the worker.
    function approveWork(uint256 id) external nonReentrant {
        Task storage task = _tasks[id];
        require(task.status == Status.Submitted, "AgentTask: work not submitted");
        require(msg.sender == task.poster, "AgentTask: only the poster can approve");

        uint256 reward = task.reward;
        address worker = task.worker;
        task.status = Status.Completed;

        emit WorkApproved(id, worker, reward);
        _pay(worker, reward, id);
    }

    /// @notice Reject submitted work; back to Accepted so the worker may resubmit.
    function rejectWork(uint256 id) external {
        Task storage task = _tasks[id];
        require(task.status == Status.Submitted, "AgentTask: work not submitted");
        require(msg.sender == task.poster, "AgentTask: only the poster can reject");

        task.status = Status.Accepted;
        task.submittedAt = 0;
        task.proof = "";
        emit WorkRejected(id, task.worker);
    }

    /// @notice Cancel an open (unaccepted) task and refund the poster.
    function cancelTask(uint256 id) external nonReentrant {
        Task storage task = _tasks[id];
        require(task.status == Status.Open, "AgentTask: only open tasks can be cancelled");
        require(msg.sender == task.poster, "AgentTask: only the poster can cancel");

        uint256 reward = task.reward;
        address poster = task.poster;
        task.status = Status.Cancelled;

        emit TaskCancelled(id, poster);
        _refund(poster, reward, id);
    }

    /// @notice Timeout handler. Two cases:
    ///         (a) Accepted, deadline passed, no submission -> poster reclaims, Expired.
    ///         (b) Submitted, poster silent > REVIEW_WINDOW after submittedAt
    ///             -> worker claims the reward, Completed.
    function claimTimeout(uint256 id) external nonReentrant {
        Task storage task = _tasks[id];

        if (task.status == Status.Accepted) {
            require(block.timestamp >= task.deadline, "AgentTask: deadline not passed");
            require(msg.sender == task.poster, "AgentTask: only poster reclaims on expiry");

            uint256 reward = task.reward;
            address poster = task.poster;
            task.status = Status.Expired;

            emit TaskExpired(id, poster);
            _refund(poster, reward, id);
        } else if (task.status == Status.Submitted) {
            require(
                block.timestamp > task.submittedAt + REVIEW_WINDOW,
                "AgentTask: review window not over"
            );
            require(msg.sender == task.worker, "AgentTask: only worker claims on silence");

            uint256 reward = task.reward;
            address worker = task.worker;
            task.status = Status.Completed;

            _pay(worker, reward, id);
        } else {
            revert("AgentTask: task not in a timeout-able state");
        }
    }

    /// @notice Pull any BNB queued for the caller after a failed push
    ///         payment or refund. Balance is zeroed before the call
    ///         (checks-effects-interactions) and the function is
    ///         nonReentrant. If the recipient still cannot receive BNB,
    ///         the call reverts and the queued amount stays claimable.
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "AgentTask: nothing to withdraw");
        pendingWithdrawals[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "AgentTask: withdrawal failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Queued pull-withdrawable BNB for an address (0 if none).
    function pendingWithdrawal(address account) external view returns (uint256) {
        return pendingWithdrawals[account];
    }

    /// @notice Read a single task.
    function getTask(uint256 id) external view returns (Task memory) {
        require(id < taskCount, "AgentTask: task does not exist");
        return _tasks[id];
    }

    function _pay(address to, uint256 amount, uint256 id) internal {
        (bool ok, ) = to.call{value: amount}("");
        if (ok) {
            emit PaymentReleased(id, to, amount);
        } else {
            // Push failed (recipient cannot receive BNB): queue the amount
            // for pull withdrawal instead of reverting, so the task's
            // funds never lock and the status change above stands.
            pendingWithdrawals[to] += amount;
            emit PaymentQueued(id, to, amount);
        }
    }

    function _refund(address to, uint256 amount, uint256 id) internal {
        (bool ok, ) = to.call{value: amount}("");
        if (ok) {
            emit Refunded(id, to, amount);
        } else {
            // Same fallback as _pay: a poster that cannot receive BNB
            // must not lock the refund forever.
            pendingWithdrawals[to] += amount;
            emit RefundQueued(id, to, amount);
        }
    }
}
