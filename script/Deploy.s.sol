// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentPayVault} from "../src/AgentPayVault.sol";

/// @notice Deploy AgentPayVault to QDay Aevum testnet (chain ID 44005).
///
/// Usage:
///   export DEPLOYER_KEY=0x...            # funded with tQDAY from the faucet
///   forge script script/Deploy.s.sol --rpc-url aevum --broadcast \
///     --private-key $DEPLOYER_KEY
///
/// Then verify the source on the Blockscout explorer:
///   forge verify-contract --chain-id 44005 --verifier blockscout \
///     --verifier-url https://explorer-test.qday.info/api \
///     <VAULT_ADDRESS> src/AgentPayVault.sol:AgentPayVault
contract Deploy is Script {
    function run() external returns (AgentPayVault vault) {
        uint256 key = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(key);
        vault = new AgentPayVault();
        vm.stopBroadcast();
        console.log("AgentPayVault deployed:", address(vault));
        console.log("Deployer / owner EOA:  ", vm.addr(key));
        console.log("Explorer: https://explorer-test.qday.info/address/%s", address(vault));
    }
}
