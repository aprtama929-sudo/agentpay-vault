// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentPayVault} from "../src/AgentPayVault.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice End-to-end demo of the AgentPay flow on Aevum testnet with tUSD8:
///
///   1. Owner creates a mandate for the agent: 250 tUSD8 per-tx cap,
///      1,000 tUSD8 total budget, 7-day expiry, payee allowlist on.
///   2. Owner funds the mandate with 1,000 tUSD8.
///   3. Owner allowlists the merchant.
///   4. Agent pays the merchant 200 tUSD8 ("invoice-001").
///   5. Owner revokes the mandate; the unspent 800 tUSD8 return instantly.
///
/// The two failure modes judges usually ask about — paying over the per-tx
/// cap and paying a non-allowlisted payee — are covered by the unit tests
/// (test_OverPerTxCapReverts, test_PayeeNotAllowedReverts) and can also be
/// replayed live with `cast call` (see README "Verify the limits yourself").
///
/// Usage:
///   export VAULT=0x...          # deployed AgentPayVault
///   export OWNER_KEY=0x...      # holds tUSD8, pays gas
///   export AGENT_KEY=0x...      # the agent EOA (needs a little tQDAY for gas)
///   export MERCHANT=0x...       # any recipient address
///   forge script script/DemoFlow.s.sol --rpc-url aevum --broadcast
contract DemoFlow is Script {
    address constant TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483; // Aevum testnet, 6 decimals

    function run() external {
        AgentPayVault vault = AgentPayVault(vm.envAddress("VAULT"));
        uint256 ownerKey = vm.envUint("OWNER_KEY");
        uint256 agentKey = vm.envUint("AGENT_KEY");
        address agent = vm.addr(agentKey);
        address merchant = vm.envAddress("MERCHANT");

        // 1–3: owner side — create, fund, allowlist
        vm.startBroadcast(ownerKey);
        uint256 id = vault.createMandate(agent, TUSD8, 250e6, 1_000e6, uint64(block.timestamp + 7 days), false);
        IERC20(TUSD8).approve(address(vault), 1_000e6);
        vault.fund(id, 1_000e6);
        vault.setPayeeAllowed(id, merchant, true);
        vm.stopBroadcast();
        console.log("Mandate created + funded, id:", id);

        // 4: agent side — pay within the mandate bounds
        vm.startBroadcast(agentKey);
        vault.pay(id, merchant, 200e6, "invoice-001");
        vm.stopBroadcast();
        console.log("Agent paid merchant 200 tUSD8. Merchant balance:", IERC20(TUSD8).balanceOf(merchant));

        // 5: owner revokes — unspent funds return immediately
        vm.startBroadcast(ownerKey);
        vault.revoke(id);
        vm.stopBroadcast();
        console.log("Mandate revoked; unspent refunded. Spendable now:", vault.spendable(id));
    }
}
