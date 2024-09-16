// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {KeeperCompatibleInterface} from
    "chainlink/contracts/src/v0.8/automation/interfaces/KeeperCompatibleInterface.sol";
import {AggregatorV3Interface} from "chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AutoDCASwapHook is BaseHook, KeeperCompatibleInterface, Ownable {
    using SafeERC20 for IERC20;

    struct DCAOrder {
        address user;
        uint256 totalAmount;
        uint256 amountPerSwap;
        uint256 frequency;
        uint256 lastExecutionTime;
        uint256 endTime;
        uint256 minPrice;
        uint256 maxPrice;
        uint256 swapsExecuted;
        uint256 totalSwaps;
        uint256 remainingBalance;
    }

    mapping(bytes32 => DCAOrder) public dcaOrders;
    address public keeper;
    uint256 public keeperFee;
    bytes32[] public dcaOrderIds;
    AggregatorV3Interface public priceFeed;
    PoolKey public poolKey;

    enum Frequency {
        Hourly,
        Daily,
        Weekly,
        Monthly
    }

    event Initialized(address indexed priceFeed, PoolKey poolKey);
    event DCAOrderCreated(
        bytes32 indexed orderId, address indexed user, uint256 totalAmount, uint256 frequency, uint256 duration
    );
    event DCAOrderCompleted(
        bytes32 indexed orderId, address indexed user, uint256 swapsExecuted, uint256 remainingBalance
    );
    event DCAOrderCancelled(bytes32 indexed orderId, address indexed user);
    event DCASwapExecuted(bytes32 indexed orderId, address indexed user, uint256 amountIn, uint256 amountOut);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) Ownable(msg.sender) {}

    function initialize(address _priceFeed, PoolKey memory _poolKey) external onlyOwner {
        require(address(priceFeed) == address(0), "AutoDCASwapHook: Already initialized");
        require(_priceFeed != address(0), "AutoDCASwapHook: Invalid price feed address");
        require(
            Currency.unwrap(_poolKey.currency0) != address(0) && Currency.unwrap(_poolKey.currency1) != address(0),
            "AutoDCASwapHook: Invalid pool currencies"
        );

        priceFeed = AggregatorV3Interface(_priceFeed);
        poolKey = _poolKey;

        emit Initialized(_priceFeed, _poolKey);
    }

    function setPoolKey(PoolKey memory _poolKey) external {
        // Add appropriate access control here
        poolKey = _poolKey;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        require(key.currency0 == poolKey.currency0 && key.currency1 == poolKey.currency1, "Invalid pool");

        // "Only check if the sender is the keeper"
        if (sender == keeper) {
            bytes32 orderId = abi.decode(data, (bytes32));
            DCAOrder storage order = dcaOrders[orderId];

            (, int256 price,,,) = priceFeed.latestRoundData();
            uint256 currentPrice = uint256(price);

            require(order.minPrice == 0 || currentPrice >= order.minPrice, "Price below minimum");
            require(order.maxPrice == 0 || currentPrice <= order.maxPrice, "Price above maximum");
            require(order.remainingBalance >= order.amountPerSwap + keeperFee, "Insufficient balance");

            order.remainingBalance -= (order.amountPerSwap + keeperFee);
        }

        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }

    function createDCA(
        uint256 totalAmount,
        Frequency frequency,
        uint256 durationInDays,
        uint256 minPrice,
        uint256 maxPrice
    ) external payable {
        require(msg.value >= keeperFee, "Insufficient keeper fee");

        uint256 frequencyInSeconds = getFrequencyInSeconds(frequency);
        uint256 totalSwaps = (durationInDays * 1 days) / frequencyInSeconds;
        uint256 amountPerSwap = totalAmount / totalSwaps;

        require(amountPerSwap > 0, "Amount per swap too low");

        bytes32 orderId = keccak256(abi.encodePacked(msg.sender, block.timestamp));

        address token0 = Currency.unwrap(poolKey.currency0);
        IERC20(token0).safeTransferFrom(msg.sender, address(this), totalAmount);

        dcaOrders[orderId] = DCAOrder({
            user: msg.sender,
            totalAmount: totalAmount,
            amountPerSwap: amountPerSwap,
            frequency: frequencyInSeconds,
            lastExecutionTime: block.timestamp,
            endTime: block.timestamp + (durationInDays * 1 days),
            minPrice: minPrice,
            maxPrice: maxPrice,
            swapsExecuted: 0,
            totalSwaps: totalSwaps,
            remainingBalance: totalAmount
        });

        dcaOrderIds.push(orderId);

        emit DCAOrderCreated(orderId, msg.sender, totalAmount, frequencyInSeconds, durationInDays);
    }

    function cancelDCA(bytes32 orderId) external {
        DCAOrder storage order = dcaOrders[orderId];
        require(order.user == msg.sender, "Not order owner");

        uint256 remainingAmount = order.remainingBalance;

        delete dcaOrders[orderId];

        for (uint256 i = 0; i < dcaOrderIds.length; i++) {
            if (dcaOrderIds[i] == orderId) {
                dcaOrderIds[i] = dcaOrderIds[dcaOrderIds.length - 1];
                dcaOrderIds.pop();
                break;
            }
        }

        if (remainingAmount > 0) {
            address token0 = Currency.unwrap(poolKey.currency0);
            IERC20(token0).safeTransfer(msg.sender, remainingAmount);
        }

        emit DCAOrderCancelled(orderId, msg.sender);
    }

    function withdraw(address token) external {
        require(
            token == Currency.unwrap(poolKey.currency0) || token == Currency.unwrap(poolKey.currency1), "Invalid token"
        );
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No balance to withdraw");

        IERC20(token).safeTransfer(msg.sender, balance);

        emit Withdrawn(msg.sender, token, balance);
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        for (uint256 i = 0; i < dcaOrderIds.length; i++) {
            bytes32 orderId = dcaOrderIds[i];
            DCAOrder storage order = dcaOrders[orderId];
            if (block.timestamp >= order.lastExecutionTime + order.frequency && block.timestamp <= order.endTime) {
                return (true, abi.encode(orderId));
            }
        }
        return (false, "");
    }

    function performUpkeep(bytes calldata performData) external override {
        require(msg.sender == keeper, "Only keeper can perform upkeep");

        bytes32 orderId = abi.decode(performData, (bytes32));
        DCAOrder storage order = dcaOrders[orderId];

        require(order.user != address(0), "Order does not exist");
        require(block.timestamp >= order.lastExecutionTime + order.frequency, "Too early");
        require(block.timestamp <= order.endTime, "DCA period ended");
        require(order.remainingBalance >= order.amountPerSwap, "Insufficient balance for swap");

        // simulate the swap
        uint256 amountOut = order.amountPerSwap;
        order.remainingBalance -= order.amountPerSwap;
        order.swapsExecuted++;
        order.lastExecutionTime = block.timestamp;

        emit DCASwapExecuted(orderId, order.user, order.amountPerSwap, amountOut);

        // Check if the DCA order has been completed
        bool isCompleted = order.swapsExecuted >= order.totalSwaps || block.timestamp >= order.endTime
            || order.remainingBalance < order.amountPerSwap;

        if (isCompleted) {
            address user = order.user;
            uint256 remainingBalance = order.remainingBalance;
            uint256 swapsExecuted = order.swapsExecuted;

            // Remove the order
            delete dcaOrders[orderId];

            // Remove the orderId from the dcaOrderIds array
            for (uint256 i = 0; i < dcaOrderIds.length; i++) {
                if (dcaOrderIds[i] == orderId) {
                    dcaOrderIds[i] = dcaOrderIds[dcaOrderIds.length - 1];
                    dcaOrderIds.pop();
                    break;
                }
            }

            // Return the remaining balance to the user if necessary
            if (remainingBalance > 0) {
                IERC20(Currency.unwrap(poolKey.currency0)).transfer(user, remainingBalance);
            }

            emit DCAOrderCompleted(orderId, user, swapsExecuted, remainingBalance);
        }
    }

    function getFrequencyInSeconds(Frequency _frequency) internal pure returns (uint256) {
        if (_frequency == Frequency.Hourly) return 1 hours;
        if (_frequency == Frequency.Daily) return 1 days;
        if (_frequency == Frequency.Weekly) return 7 days;
        if (_frequency == Frequency.Monthly) return 30 days;
        revert("Invalid frequency");
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
    }

    function setKeeperFee(uint256 _fee) external onlyOwner {
        keeperFee = _fee;
    }

    function getOrderDetails(bytes32 orderId)
        public
        view
        returns (
            address user,
            uint256 totalAmount,
            uint256 amountPerSwap,
            uint256 frequency,
            uint256 lastExecutionTime,
            uint256 endTime,
            uint256 minPrice,
            uint256 maxPrice,
            uint256 swapsExecuted,
            uint256 totalSwaps,
            uint256 remainingBalance
        )
    {
        DCAOrder storage order = dcaOrders[orderId];
        return (
            order.user,
            order.totalAmount,
            order.amountPerSwap,
            order.frequency,
            order.lastExecutionTime,
            order.endTime,
            order.minPrice,
            order.maxPrice,
            order.swapsExecuted,
            order.totalSwaps,
            order.remainingBalance
        );
    }

    function getDcaOrderIdsLength() public view returns (uint256) {
        return dcaOrderIds.length;
    }

    function isDcaOrderIdPresent(bytes32 orderId) public view returns (bool) {
        for (uint256 i = 0; i < dcaOrderIds.length; i++) {
            if (dcaOrderIds[i] == orderId) {
                return true;
            }
        }
        return false;
    }
}
