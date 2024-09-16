// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/AutoDCASwapHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import "forge-std/console.sol";

contract AutoDCASwapHookTest is Test, Deployers {
    AutoDCASwapHook public hook;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockPriceFeed public priceFeed;
    address public user = address(0x1);
    address public keeper = address(0x2);

    function setUp() public {
        deployFreshManagerAndRouters();
        tokenA = new MockERC20("Token A", "TOKENA", 18);
        tokenB = new MockERC20("Token B", "TOKENB", 18);

        // Ensure tokenA has a lower address than tokenB
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }

        Currency tokenACurrency = Currency.wrap(address(tokenA));
        Currency tokenBCurrency = Currency.wrap(address(tokenB));

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        deployCodeTo("AutoDCASwapHook.sol", abi.encode(manager, address(tokenA), address(tokenB)), address(flags));

        hook = AutoDCASwapHook(address(flags));

        // Set up test addresses
        user = address(0x1);
        keeper = address(0x2);

        // Set keeper
        hook.setKeeper(keeper);

        // Set keeper fee
        hook.setKeeperFee(0.01 ether);

        // Initialize a pool
        (key,) = initPool(tokenACurrency, tokenBCurrency, hook, 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        // Set the pool key in the hook
        hook.setPoolKey(key);
    }

    function testCrearOrdenDCA() public {
        vm.startPrank(user);

        // Add 1 ETH to the user
        vm.deal(user, 1 ether);

        // Give tokens to the user
        tokenA.mint(user, 100 ether);

        tokenA.approve(address(hook), 100 ether);

        bool success;
        try hook.createDCA{value: 0.01 ether}(100 ether, AutoDCASwapHook.Frequency.Daily, 30, 900 * 1e8, 1100 * 1e8) {
            success = true;
        } catch Error(string memory reason) {
            emit log_string(reason);
            success = false;
        } catch (bytes memory) /*lowLevelData*/ {
            emit log_string("Low level error");
            success = false;
        }

        assertTrue(success, "createDCA failed");

        if (success) {
            bytes32 orderId = keccak256(abi.encodePacked(user, block.timestamp));

            (
                address orderUser,
                uint256 orderTotalAmount,
                ,
                uint256 orderFrequency,
                ,
                uint256 orderEndTime,
                uint256 orderMinPrice,
                uint256 orderMaxPrice,
                ,
                ,
            ) = hook.dcaOrders(orderId);

            assertEq(orderUser, user, unicode"Incorrect User");
            assertEq(orderTotalAmount, 100 ether, unicode"Incorrect amount");
            assertEq(orderFrequency, 1 days, unicode"incorrecta frecuency");
            assertEq(orderEndTime, block.timestamp + 30 days, unicode"Incorrect end time");
            assertEq(orderMinPrice, 900 * 1e8, unicode"Incorrect minimum price");
            assertEq(orderMaxPrice, 1100 * 1e8, unicode"Incorrect maximum price");
        }

        vm.stopPrank();
    }

    function testCancelDCA() public {
        vm.startPrank(user);
        vm.deal(user, 1 ether);
        tokenA.mint(user, 100 ether);
        tokenA.approve(address(hook), 100 ether);

        hook.createDCA{value: 0.01 ether}(100 ether, AutoDCASwapHook.Frequency.Daily, 30, 900 * 1e8, 1100 * 1e8);

        bytes32 orderId = keccak256(abi.encodePacked(user, block.timestamp));

        (address orderUser,,,,,,,,,, uint256 remainingBalance) = hook.dcaOrders(orderId);
        assertEq(orderUser, user, "Incorrect user");
        assertEq(remainingBalance, 100 ether, "Incorrect remaining balance");

        hook.cancelDCA(orderId);

        (orderUser,,,,,,,,,, remainingBalance) = hook.dcaOrders(orderId);
        assertEq(orderUser, address(0), "Order not deleted correctly");
        assertEq(remainingBalance, 0, "Remaining balance not returned correctly");
        assertEq(tokenA.balanceOf(user), 100 ether, "Funds not returned correctly");
        vm.stopPrank();
    }

    function testCheckAndPerformUpkeep() public {
        vm.startPrank(user);
        vm.deal(user, 1 ether);
        tokenA.mint(user, 100 ether);
        tokenA.approve(address(hook), 100 ether);

        // Create DCA order
        hook.createDCA{value: 0.01 ether}(100 ether, AutoDCASwapHook.Frequency.Hourly, 30, 900 * 1e8, 1100 * 1e8);
        vm.stopPrank();

        bytes32 orderId = keccak256(abi.encodePacked(user, block.timestamp));

        vm.warp(block.timestamp + 1 hours);

        // Verify checkUpkeep
        (bool upkeepNeeded, bytes memory performData) = hook.checkUpkeep("");
        assertTrue(upkeepNeeded, "Upkeep should be necessary");
        assertEq(abi.decode(performData, (bytes32)), orderId, "Incorrect performData");

        // Perform upkeep
        vm.startPrank(keeper);
        hook.performUpkeep(performData);
        vm.stopPrank();

        // Verify that the DCA order was updated correctly
        (,,,, uint256 lastExecutionTime,,,, uint256 swapsExecuted,, uint256 remainingBalance) = hook.dcaOrders(orderId);

        assertEq(lastExecutionTime, block.timestamp, "Incorrect time for last execution");
        assertEq(swapsExecuted, 1, "NNumber of swaps executed is incorrect");
        assertTrue(remainingBalance < 100 ether, "Remaining amount should be less than 100");

        // Verificar que checkUpkeep ahora devuelve falso
        (upkeepNeeded,) = hook.checkUpkeep("");
        assertFalse(upkeepNeeded, "Unkeep should not be needed");
    }

    function testCompleteDCAOrder() public {
        // Initial setup
        vm.startPrank(user);
        vm.deal(user, 1 ether);
        tokenA.mint(user, 100 ether);
        tokenA.approve(address(hook), 100 ether);

        // Create a DCA order
        uint256 totalAmount = 10 ether;
        uint256 durationInDays = 5;
        hook.createDCA{value: 0.01 ether}(
            totalAmount, AutoDCASwapHook.Frequency.Daily, durationInDays, 900 * 1e8, 1100 * 1e8
        );

        bytes32 orderId =
            hook.getDcaOrderIdsLength() > 0 ? hook.dcaOrderIds(hook.getDcaOrderIdsLength() - 1) : bytes32(0);
        require(orderId != bytes32(0), "DCA order not created");

        vm.stopPrank();

        MockPriceFeed mockPriceFeed = new MockPriceFeed(1000 * 1e8);
        hook.initialize(address(mockPriceFeed), key);

        uint256 initialBalance = totalAmount;

        for (uint256 i = 0; i < durationInDays; i++) {
            vm.warp(block.timestamp + 1 days);

            (bool upkeepNeeded, bytes memory performData) = hook.checkUpkeep("");
            assertTrue(upkeepNeeded, "Upkeep should be needed");

            vm.startPrank(keeper);
            hook.performUpkeep(performData);
            vm.stopPrank();

            (
                address orderUser,
                ,
                uint256 amountPerSwap,
                ,
                uint256 lastExecutionTime,
                ,
                ,
                ,
                uint256 swapsExecuted,
                ,
                uint256 remainingBalance
            ) = hook.getOrderDetails(orderId);

            if (i < durationInDays - 1) {
                assertEq(lastExecutionTime, block.timestamp, "Last execution time should be updated");
                assertEq(
                    swapsExecuted,
                    i + 1,
                    string(abi.encodePacked("Should have executed ", vm.toString(i + 1), " swap(s)"))
                );

                uint256 expectedRemainingBalance = initialBalance - ((i + 1) * amountPerSwap);
                assertEq(remainingBalance, expectedRemainingBalance, "Remaining balance is incorrect");
            } else {
                // For the last swap, the order should be completed and removed
                assertEq(orderUser, address(0), "DCA order should be removed after completion");
                assertFalse(hook.isDcaOrderIdPresent(orderId), "OrderId should not be present after completion");
            }
        }

        // Verify that remaining funds (if any) have been returned to the user
        uint256 finalBalance = tokenA.balanceOf(user);
        assertGe(finalBalance, 90 ether, "User should have received remaining funds");
    }

    function testWithdraw() public {
        // Setup
        vm.startPrank(user);
        vm.deal(user, 1 ether);
        tokenA.mint(address(hook), 100 ether);
        tokenB.mint(address(hook), 50 ether);

        // Initial balances
        uint256 initialBalanceA = tokenA.balanceOf(address(hook));
        uint256 initialBalanceB = tokenB.balanceOf(address(hook));

        // Withdraw tokenA
        hook.withdraw(address(tokenA));

        // Check balances after withdrawing tokenA
        assertEq(tokenA.balanceOf(address(hook)), 0, "Hook should have 0 tokenA after withdrawal");
        assertEq(tokenA.balanceOf(user), initialBalanceA, "User should have received all tokenA");

        // Withdraw tokenB
        hook.withdraw(address(tokenB));

        // Check balances after withdrawing tokenB
        assertEq(tokenB.balanceOf(address(hook)), 0, "Hook should have 0 tokenB after withdrawal");
        assertEq(tokenB.balanceOf(user), initialBalanceB, "User should have received all tokenB");

        vm.stopPrank();
    }

    function testWithdrawUnauthorizedToken() public {
        MockERC20 unauthorizedToken = new MockERC20("Unauthorized", "UNAUTH", 18);

        vm.startPrank(user);
        vm.expectRevert("Invalid token");
        hook.withdraw(address(unauthorizedToken));
        vm.stopPrank();
    }

    function testSetKeeperAndFee() public {
        address newKeeper = address(0x3);
        uint256 newFee = 0.02 ether;

        vm.prank(hook.owner());
        hook.setKeeper(newKeeper);
        assertEq(hook.keeper(), newKeeper, "Keeper should be updated");

        vm.prank(hook.owner());
        hook.setKeeperFee(newFee);
        assertEq(hook.keeperFee(), newFee, "Keeper fee should be updated");
    }

    function testCreateDCAWithInsufficientKeeperFee() public {
        vm.startPrank(user);
        vm.deal(user, 0.009 ether); // Less than the required keeper fee
        tokenA.mint(user, 100 ether);
        tokenA.approve(address(hook), 100 ether);

        vm.expectRevert("Insufficient keeper fee");
        hook.createDCA{value: 0.009 ether}(100 ether, AutoDCASwapHook.Frequency.Daily, 30, 900 * 1e8, 1100 * 1e8);

        vm.stopPrank();
    }

    function testCancelDCAUnauthorized() public {
        // Create a DCA order as user
        vm.startPrank(user);
        vm.deal(user, 1 ether);
        tokenA.mint(user, 100 ether);
        tokenA.approve(address(hook), 100 ether);

        hook.createDCA{value: 0.01 ether}(100 ether, AutoDCASwapHook.Frequency.Daily, 30, 900 * 1e8, 1100 * 1e8);

        bytes32 orderId = keccak256(abi.encodePacked(user, block.timestamp));
        vm.stopPrank();

        // Try to cancel the order as a different address
        address unauthorizedUser = address(0x4);
        vm.prank(unauthorizedUser);
        vm.expectRevert("Not order owner");
        hook.cancelDCA(orderId);
    }
}
