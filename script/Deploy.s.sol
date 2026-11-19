// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import "../contracts/AgentTaskEscrow.sol";

/// @notice Deploy AgentTaskEscrow. No constructor args.
/// @dev Usage (dry run): forge script script/Deploy.s.sol
///      Usage (BSC mainnet, parent only, after preview):
///        forge script script/Deploy.s.sol --rpc-url <bsc-rpc> --broadcast
///        --private-key <key> --verify --etherscan-api-key <bscscan-key>
///      Then verify source on BscScan (Sourcify is the reliable path here).
contract Deploy is Script {
    function run() external returns (AgentTaskEscrow escrow) {
        vm.startBroadcast();
        escrow = new AgentTaskEscrow();
        vm.stopBroadcast();
        console.log("AgentTaskEscrow deployed at:", address(escrow));
    }
}
