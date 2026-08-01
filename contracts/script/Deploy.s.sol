// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Ask} from "../src/Ask.sol";

/// Deploy ASK to Robinhood Chain (Arbitrum Orbit L2).
///
///   export ROBINHOOD_RPC_URL=<rpc url>
///   export PRIVATE_KEY=<deployer key>
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url "$ROBINHOOD_RPC_URL" --broadcast
///
/// Verification (Robinhood Chain explorer is Blockscout-based):
///   forge verify-contract <address> src/Ask.sol:Ask \
///     --verifier blockscout --verifier-url <explorer api url>
contract Deploy is Script {
    function run() external returns (Ask ask) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        ask = new Ask();
        vm.stopBroadcast();

        console2.log("Ask deployed at:", address(ask));
        console2.log("owner:", ask.owner());
        console2.log("start price (wei):", ask.START_PRICE());
        console2.log("timer max (s):", ask.TIMER_MAX());
        console2.log("timer bonus per take (s):", ask.TIMER_BONUS());
        console2.log("WITHDRAW_ENABLED:", ask.WITHDRAW_ENABLED());
    }
}
