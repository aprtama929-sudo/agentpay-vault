// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentPayVault} from "../src/AgentPayVault.sol";

/// @dev Minimal 6-decimal ERC-20 mock standing in for tUSD8 in local tests.
contract MockUSD8 {
    string public name = "Test USD8";
    string public symbol = "tUSD8";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract AgentPayVaultTest is Test {
    AgentPayVault vault;
    MockUSD8 usd;

    address owner = makeAddr("owner"); // principal / merchant ops wallet
    address agent = makeAddr("agent"); // the AI agent
    address merchant = makeAddr("merchant");
    address stranger = makeAddr("stranger");

    uint256 constant PER_TX = 250e6; // 250 tUSD8 per payment
    uint256 constant BUDGET = 1_000e6; // 1,000 tUSD8 total

    function setUp() public {
        vault = new AgentPayVault();
        usd = new MockUSD8();
        usd.mint(owner, 10_000e6);
        vm.prank(owner);
        usd.approve(address(vault), type(uint256).max);
    }

    function _create(bool allowAny) internal returns (uint256 id) {
        vm.prank(owner);
        id = vault.createMandate(agent, address(usd), PER_TX, BUDGET, uint64(block.timestamp + 7 days), allowAny);
    }

    function _createFunded(bool allowAny) internal returns (uint256 id) {
        id = _create(allowAny);
        vm.prank(owner);
        vault.fund(id, BUDGET);
    }

    // ------------------------------------------------------------ happy path

    function test_EndToEndFlow() public {
        uint256 id = _createFunded(false);

        vm.prank(owner);
        vault.setPayeeAllowed(id, merchant, true);

        vm.prank(agent);
        vault.pay(id, merchant, 200e6, "invoice-001");

        assertEq(usd.balanceOf(merchant), 200e6);
        assertEq(vault.spendable(id), 800e6);

        AgentPayVault.Mandate memory m = vault.getMandate(id);
        assertEq(m.spent, 200e6);
        assertEq(m.funded, BUDGET);
        assertEq(m.owner, owner);
        assertEq(m.agent, agent);
    }

    function test_AllowAnyPayeeSkipsAllowlist() public {
        uint256 id = _createFunded(true);
        vm.prank(agent);
        vault.pay(id, stranger, 100e6, "any-payee ok");
        assertEq(usd.balanceOf(stranger), 100e6);
    }

    // ------------------------------------------------------------ hard limits

    function test_OverPerTxCapReverts() public {
        uint256 id = _createFunded(true);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentPayVault.OverPerTxCap.selector, PER_TX + 1, PER_TX));
        vault.pay(id, merchant, PER_TX + 1, "too big");
    }

    function test_OverBudgetRevertsAcrossPayments() public {
        uint256 id = _createFunded(true);
        vm.startPrank(agent);
        vault.pay(id, merchant, PER_TX, "1");
        vault.pay(id, merchant, PER_TX, "2");
        vault.pay(id, merchant, PER_TX, "3");
        vault.pay(id, merchant, PER_TX, "4"); // budget exactly exhausted
        vm.expectRevert(abi.encodeWithSelector(AgentPayVault.OverBudget.selector, 1, 0));
        vault.pay(id, merchant, 1, "one wei too far");
        vm.stopPrank();
    }

    function test_UnfundedMandateCannotPay() public {
        uint256 id = _create(true); // created but never funded
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentPayVault.InsufficientFunds.selector, 10e6, 0));
        vault.pay(id, merchant, 10e6, "no funds");
    }

    function test_ExpiredMandateCannotPay() public {
        uint256 id = _createFunded(true);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentPayVault.MandateExpired.selector, id));
        vault.pay(id, merchant, 10e6, "too late");
    }

    function test_PayeeNotAllowlistedReverts() public {
        uint256 id = _createFunded(false);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentPayVault.PayeeNotAllowed.selector, id, merchant));
        vault.pay(id, merchant, 10e6, "not on the list");
    }

    function test_OnlyAgentCanPay() public {
        uint256 id = _createFunded(true);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentPayVault.NotAgent.selector, id));
        vault.pay(id, merchant, 10e6, "impostor");
    }

    function test_OnlyOwnerCanFundAndRevoke() public {
        uint256 id = _create(true);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentPayVault.NotOwner.selector, id));
        vault.fund(id, 1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentPayVault.NotOwner.selector, id));
        vault.revoke(id);
    }

    // ------------------------------------------------------- revoke & closing

    function test_RevokeRefundsUnspentAndBlocksPayments() public {
        uint256 id = _createFunded(true);

        vm.prank(agent);
        vault.pay(id, merchant, PER_TX, "spend some"); // spends 250 (the per-tx cap)

        uint256 ownerBefore = usd.balanceOf(owner);
        vm.prank(owner);
        vault.revoke(id);

        // unspent = 1,000 - 250 = 750 returns to owner
        assertEq(usd.balanceOf(owner), ownerBefore + 750e6);
        assertEq(vault.spendable(id), 0);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentPayVault.MandateRevokedError.selector, id));
        vault.pay(id, merchant, 1, "dead mandate");
    }

    function test_CloseExpiredReturnsFundsToOwner() public {
        uint256 id = _createFunded(true);
        vm.warp(block.timestamp + 7 days + 1);

        uint256 ownerBefore = usd.balanceOf(owner);
        vault.closeExpired(id); // callable by anyone
        assertEq(usd.balanceOf(owner), ownerBefore + BUDGET);
    }

    function test_CloseBeforeExpiryReverts() public {
        uint256 id = _createFunded(true);
        vm.expectRevert(abi.encodeWithSelector(AgentPayVault.MandateNotExpired.selector, id));
        vault.closeExpired(id);
    }

    // ------------------------------------------------------------- validation

    function test_CreateValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(AgentPayVault.InvalidLimits.selector);
        vault.createMandate(agent, address(usd), 0, BUDGET, uint64(block.timestamp + 1 days), true);

        vm.expectRevert(AgentPayVault.InvalidLimits.selector);
        vault.createMandate(agent, address(usd), BUDGET + 1, BUDGET, uint64(block.timestamp + 1 days), true);

        vm.expectRevert(AgentPayVault.InvalidLimits.selector);
        vault.createMandate(agent, address(usd), PER_TX, BUDGET, uint64(block.timestamp), true); // not future

        vm.expectRevert(AgentPayVault.ZeroAddress.selector);
        vault.createMandate(address(0), address(usd), PER_TX, BUDGET, uint64(block.timestamp + 1 days), true);
        vm.stopPrank();
    }
}
