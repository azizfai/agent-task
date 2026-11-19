// AgentTask frontend — static, no backend, no keys collected.
// Every asset action is a transaction the user confirms in their own wallet.
// Fill in CONTRACT_ADDRESS after the contract is deployed on BNB Chain.
const CONTRACT_ADDRESS = "0x5f1F8AEA183b4a36ec420d1b25A7808De5aFCD6d"; // TODO: deployed address
const BSC_CHAIN_ID = 56;
const BSC_RPC = "https://bsc-dataseed.binance.org/";
const BSCSCAN = "https://bscscan.com";

const ABI = [
  "function AGENT_ID() view returns (address)",
  "function REVIEW_WINDOW() view returns (uint256)",
  "function MAX_DURATION() view returns (uint256)",
  "function taskCount() view returns (uint256)",
  "function isAgentHolder(address) view returns (bool)",
  "function getTask(uint256) view returns (tuple(uint256 id, address poster, address worker, string title, string description, uint256 reward, uint256 deadline, uint256 submittedAt, string proof, uint8 status))",
  "function postTask(string title, string description, uint256 deadline) payable returns (uint256)",
  "function acceptTask(uint256 id)",
  "function submitWork(uint256 id, string proof)",
  "function approveWork(uint256 id)",
  "function rejectWork(uint256 id)",
  "function cancelTask(uint256 id)",
  "function claimTimeout(uint256 id)",
  "event TaskPosted(uint256 indexed id, address indexed poster, uint256 reward, uint256 deadline)",
  "event TaskAccepted(uint256 indexed id, address indexed worker)",
  "event WorkSubmitted(uint256 indexed id, address indexed worker)",
  "event WorkApproved(uint256 indexed id, address indexed worker, uint256 reward)",
  "event WorkRejected(uint256 indexed id, address indexed worker)",
  "event TaskCancelled(uint256 indexed id, address indexed poster)",
  "event TaskExpired(uint256 indexed id, address indexed poster)",
  "event PaymentReleased(uint256 indexed id, address indexed to, uint256 amount)",
  "event Refunded(uint256 indexed id, address indexed to, uint256 amount)",
];

const STATUS = ["Open", "Accepted", "Submitted", "Completed", "Cancelled", "Expired"];

const $ = (id) => document.getElementById(id);
const readProvider = new ethers.JsonRpcProvider(BSC_RPC);
let signer = null;
let account = null;
let contract = null; // signer-connected, set after connect
let readContract = null;
let isHolder = false;

function setStatus(msg) {
  $("status").textContent = msg;
}

function short(addr) {
  return addr ? addr.slice(0, 6) + "…" + addr.slice(-4) : "—";
}

function txLink(hash) {
  return `${BSCSCAN}/tx/${hash}`;
}

async function ensureBsc() {
  const net = await signer.provider.getNetwork();
  if (Number(net.chainId) === BSC_CHAIN_ID) return true;
  try {
    await window.ethereum.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: "0x38" }],
    });
    return true;
  } catch (e) {
    setStatus("Please switch your wallet to BNB Chain (chain 56) and try again.");
    return false;
  }
}

async function sendTx(promiseFn, label) {
  if (!signer) { setStatus("Connect your wallet first."); return; }
  if (!(await ensureBsc())) return;
  try {
    setStatus(`${label} — waiting for your confirmation in the wallet…`);
    const tx = await promiseFn();
    setStatus(`${label} — sent: ${txLink(tx.hash)}\nWaiting for confirmation…`);
    await tx.wait();
    setStatus(`${label} — confirmed: ${txLink(tx.hash)}`);
    await loadTasks();
  } catch (e) {
    setStatus(`${label} — failed: ${e.shortMessage || e.message || e}`);
  }
}

async function connect() {
  if (!window.ethereum) {
    setStatus("No injected wallet found. Install Binance Wallet or MetaMask and reload.");
    return;
  }
  try {
    const provider = new ethers.BrowserProvider(window.ethereum);
    const accounts = await provider.send("eth_requestAccounts", []);
    account = accounts[0];
    signer = await provider.getSigner();
    contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, signer);
    $("account").textContent = short(account);
    const net = await provider.getNetwork();
    $("netInfo").textContent = `Network: ${net.name || "chain " + net.chainId} (${net.chainId})${Number(net.chainId) === BSC_CHAIN_ID ? " — BNB Chain ✓" : " — please switch to BNB Chain (56)"}`;
    await refreshHolder();
    await loadTasks();
    setStatus("Connected: " + account);
  } catch (e) {
    setStatus("Connect failed: " + (e.shortMessage || e.message || e));
  }
}

async function refreshHolder() {
  if (!readContract || !account) return;
  try {
    isHolder = await readContract.isAgentHolder(account);
    $("holderBadge").innerHTML = isHolder
      ? '<span class="badge holder">✓ Agent ID holder</span> <span class="muted">— you can accept tasks</span>'
      : '<span class="badge noholder">No Agent ID found</span> <span class="muted">— you can post tasks, but only Agent ID holders can accept them</span>';
  } catch (e) {
    $("holderBadge").innerHTML = '<span class="badge noholder">Could not check Agent ID</span>';
  }
}

function taskCard(t) {
  const reward = ethers.formatEther(t.reward);
  const deadline = new Date(Number(t.deadline) * 1000).toLocaleString();
  const status = STATUS[t.status] || ("#" + t.status);
  const mine = account && account.toLowerCase() === t.poster.toLowerCase();
  const iamWorker = account && account.toLowerCase() === t.worker.toLowerCase();
  const now = Math.floor(Date.now() / 1000);
  const div = document.createElement("div");
  div.className = "card";
  div.innerHTML = `
    <div class="task-head">
      <h3>#${t.id} — ${escapeHtml(t.title)}</h3>
      <span class="badge status-${t.status}">${status}</span>
    </div>
    <p>${escapeHtml(t.description)}</p>
    <p class="muted">Reward: <b style="color:#fff">${reward} BNB</b> · Deadline: ${deadline}<br>
    Poster: ${short(t.poster)}${mine ? " (you)" : ""} · Worker: ${t.worker === ethers.ZeroAddress ? "—" : short(t.worker) + (iamWorker ? " (you)" : "")}<br>
    ${t.proof ? `Proof: ${escapeHtml(t.proof)}<br>` : ""}
    ${t.submittedAt ? `Submitted: ${new Date(Number(t.submittedAt) * 1000).toLocaleString()}<br>` : ""}</p>
    <div class="actions"></div>`;
  const actions = div.querySelector(".actions");
  const deployed = CONTRACT_ADDRESS !== ethers.ZeroAddress;

  const addBtn = (label, cls, fn, disabledReason) => {
    const b = document.createElement("button");
    b.textContent = label;
    if (cls) b.className = cls;
    b.disabled = !deployed || !!disabledReason;
    if (disabledReason) b.title = disabledReason;
    b.onclick = fn;
    actions.appendChild(b);
  };

  if (t.status === 0) {
    addBtn("Accept task", "", () => sendTx(() => contract.acceptTask(t.id), `Accept task #${t.id}`),
      !account ? "Connect wallet" : !isHolder ? "Only Agent ID holders can accept" : mine ? "Poster cannot accept own task" : "");
    addBtn("Cancel (refund)", "danger", () => sendTx(() => contract.cancelTask(t.id), `Cancel task #${t.id}`),
      !mine ? "Only the poster can cancel" : "");
  }
  if (t.status === 1) {
    addBtn("Submit work", "", () => {
      const proof = prompt("Proof of completed work (text or URL):");
      if (proof) sendTx(() => contract.submitWork(t.id, proof), `Submit work #${t.id}`);
    }, !iamWorker ? "Only the assigned worker can submit" : now >= Number(t.deadline) ? "Deadline passed" : "");
    addBtn("Claim timeout (poster refund)", "secondary", () => sendTx(() => contract.claimTimeout(t.id), `Claim timeout #${t.id}`),
      !mine ? "Only the poster reclaims on expiry" : now < Number(t.deadline) ? "Deadline has not passed yet" : "");
  }
  if (t.status === 2) {
    addBtn("Approve & pay", "", () => sendTx(() => contract.approveWork(t.id), `Approve work #${t.id}`),
      !mine ? "Only the poster can approve" : "");
    addBtn("Reject", "secondary", () => sendTx(() => contract.rejectWork(t.id), `Reject work #${t.id}`),
      !mine ? "Only the poster can reject" : "");
    const silentFor = now - Number(t.submittedAt);
    addBtn("Claim reward (poster silent 3d)", "", () => sendTx(() => contract.claimTimeout(t.id), `Claim reward #${t.id}`),
      !iamWorker ? "Only the worker can claim on poster silence" : silentFor <= 3 * 86400 ? `Review window still open (${Math.ceil((3 * 86400 - silentFor) / 3600)}h left)` : "");
  }
  return div;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

async function loadTasks() {
  const list = $("taskList");
  try {
    const count = Number(await readContract.taskCount());
    list.innerHTML = "";
    if (count === 0) {
      list.innerHTML = '<p class="muted">No tasks yet — post the first one above.</p>';
      return;
    }
    for (let i = count - 1; i >= 0; i--) {
      const t = await readContract.getTask(i);
      list.appendChild(taskCard(t));
    }
  } catch (e) {
    list.innerHTML = '<p class="muted">Could not load tasks: ' + escapeHtml(e.shortMessage || e.message || e) + "</p>";
  }
}

async function postTask() {
  if (!signer) { setStatus("Connect your wallet first."); return; }
  const title = $("fTitle").value.trim();
  const desc = $("fDesc").value.trim();
  const reward = $("fReward").value.trim();
  const days = Number($("fDays").value);
  if (!title || !desc || !reward || Number(reward) <= 0) {
    setStatus("Fill in title, description and a reward above 0 BNB.");
    return;
  }
  if (days < 1 || days > 30) { setStatus("Deadline must be 1–30 days."); return; }
  const deadline = Math.floor(Date.now() / 1000) + days * 86400;
  await sendTx(
    () => contract.postTask(title, desc, deadline, { value: ethers.parseEther(reward) }),
    "Post task",
  );
}

async function init() {
  $("contractAddr").textContent = CONTRACT_ADDRESS;
  $("contractLink").href = `${BSCSCAN}/address/${CONTRACT_ADDRESS}`;
  readContract = new ethers.Contract(CONTRACT_ADDRESS, ABI, readProvider);
  if (CONTRACT_ADDRESS === ethers.ZeroAddress) {
    $("deployBanner").style.display = "block";
    $("taskList").innerHTML = '<p class="muted">Contract not deployed yet.</p>';
    $("postBtn").disabled = true;
  } else {
    await loadTasks();
  }
  $("connectBtn").onclick = connect;
  $("postBtn").onclick = postTask;
  if (window.ethereum) {
    window.ethereum.on("accountsChanged", () => location.reload());
    window.ethereum.on("chainChanged", () => location.reload());
  }
}

init();
