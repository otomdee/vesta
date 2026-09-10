// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { MockLaunchToken } from "../../contracts/MockLaunchToken.sol";
import { VestaStrategy, IMintableLaunchToken } from "../../contracts/VestaStrategy.sol";
import { VestaCovenantVault } from "../../contracts/VestaCovenantVault.sol";
import { MockCcaAdapter } from "../../contracts/mocks/MockCcaAdapter.sol";
import { MockLiquidityAdapter } from "../../contracts/mocks/MockLiquidityAdapter.sol";

contract EnrollmentHandler is Test {
    VestaCovenantVault internal immutable vault;
    address[] internal users;
    mapping(address user => bool seen) internal known;

    constructor(VestaCovenantVault vault_) {
        vault = vault_;
    }

    function enroll(address user, uint16 bps, uint96 amount) external {
        user = _user(user);
        bps = uint16(bound(bps, 0, 10_000));
        amount = uint96(bound(amount, 1, 5 ether));
        vm.deal(user, amount);
        vm.prank(user);
        vault.enrollCovenant{ value: amount }(bps);
    }

    function update(address user, uint16 bps, uint96 amount) external {
        user = _user(user);
        VestaCovenantVault.Commitment memory commitment = vault.commitmentOf(user);
        if (!commitment.active) return;
        bps = uint16(bound(bps, 0, 10_000));
        amount = uint96(bound(amount, 0, 5 ether));
        vm.deal(user, amount);
        vm.prank(user);
        vault.updateCovenant{ value: amount }(bps);
    }

    function cancel(address user) external {
        user = _user(user);
        if (!vault.commitmentOf(user).active) return;
        vm.prank(user);
        vault.cancelCovenant();
    }

    function usersLength() external view returns (uint256) {
        return users.length;
    }

    function userAt(uint256 index) external view returns (address) {
        return users[index];
    }

    function _user(address user) private returns (address) {
        user = address(uint160(uint256(keccak256(abi.encode(user)))) | 1);
        if (!known[user]) {
            known[user] = true;
            users.push(user);
        }
        return user;
    }
}

contract VestaEnrollmentInvariantTest is StdInvariant, Test {
    VestaCovenantVault internal vault;
    EnrollmentHandler internal handler;

    function setUp() public {
        MockLaunchToken token = new MockLaunchToken();
        MockCcaAdapter auction = new MockCcaAdapter();
        MockLiquidityAdapter liquidity = new MockLiquidityAdapter();
        VestaStrategy strategy = new VestaStrategy(
            address(0xCAFE), IMintableLaunchToken(address(token)), auction, liquidity, 7 days, 1_000
        );
        vault = strategy.vault();
        strategy.openEnrollment();
        handler = new EnrollmentHandler(vault);
        targetContract(address(handler));
    }

    /// @notice Escrow is fully backed during the enrollment state; no unrelated ETH enters the vault.
    function invariant_escrowIsBackedByVaultBalance() public view {
        assertEq(address(vault).balance, vault.totalEscrowedEth());
    }

    /// @notice Stateful enrollment mutations can never persist a commitment above the BPS denominator.
    function invariant_commitmentBpsNeverExceedsDenominator() public view {
        uint256 length = handler.usersLength();
        for (uint256 i; i < length; ++i) {
            VestaCovenantVault.Commitment memory commitment = vault.commitmentOf(handler.userAt(i));
            assertLe(commitment.commitmentBps, vault.BPS());
        }
    }
}
