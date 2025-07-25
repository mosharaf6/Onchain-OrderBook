// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {ComplexOrderBook} from "../src/OrderBook.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/**
 * @title OrderBook Demo Script
 * @notice Demonstrates how to use the ComplexOrderBook contract
 */
contract OrderBookDemo is Script {
    ComplexOrderBook public orderBook;
    MockERC20 public baseToken;  // e.g., WETH
    MockERC20 public quoteToken; // e.g., USDC
    
    address public trader1 = address(0x1);
    address public trader2 = address(0x2);
    
    function run() public {
        vm.startBroadcast();
        
        // Deploy contracts
        console.log("Deploying OrderBook and tokens...");
        orderBook = new ComplexOrderBook();
        baseToken = new MockERC20("Wrapped Ether", "WETH", 18);
        quoteToken = new MockERC20("USD Coin", "USDC", 6);
        
        console.log("OrderBook deployed at:", address(orderBook));
        console.log("Base Token (WETH) deployed at:", address(baseToken));
        console.log("Quote Token (USDC) deployed at:", address(quoteToken));
        
        // Add trading pair
        uint256 pairId = orderBook.addTradingPair(
            address(baseToken),
            address(quoteToken)
        );
        console.log("Trading pair created with ID:", pairId);
        
        // Mint tokens to traders
        baseToken.mint(trader1, 100 * 1e18);  // 100 WETH
        quoteToken.mint(trader1, 500000 * 1e6); // 500,000 USDC
        
        baseToken.mint(trader2, 50 * 1e18);   // 50 WETH
        quoteToken.mint(trader2, 250000 * 1e6); // 250,000 USDC
        
        console.log("Tokens minted to traders");
        
        vm.stopBroadcast();
        
        // Demonstrate trading (these would be separate transactions in practice)
        demonstrateTrading(pairId);
    }
    
    function demonstrateTrading(uint256 pairId) internal {
        console.log("\n=== Trading Demonstration ===");
        
        // Trader1 approvals
        vm.startPrank(trader1);
        baseToken.approve(address(orderBook), type(uint256).max);
        quoteToken.approve(address(orderBook), type(uint256).max);
        vm.stopPrank();
        
        // Trader2 approvals
        vm.startPrank(trader2);
        baseToken.approve(address(orderBook), type(uint256).max);
        quoteToken.approve(address(orderBook), type(uint256).max);
        vm.stopPrank();
        
        // Trader1 places a buy order
        vm.startPrank(trader1);
        uint256 buyOrderId = orderBook.placeOrder(
            pairId,
            ComplexOrderBook.OrderSide.BUY,
            ComplexOrderBook.OrderType.LIMIT,
            2000 * 1e6,  // Price: 2000 USDC per WETH
            10 * 1e18    // Amount: 10 WETH
        );
        console.log("Trader1 placed buy order ID:", buyOrderId);
        vm.stopPrank();
        
        // Trader2 places a sell order that matches
        vm.startPrank(trader2);
        uint256 sellOrderId = orderBook.placeOrder(
            pairId,
            ComplexOrderBook.OrderSide.SELL,
            ComplexOrderBook.OrderType.LIMIT,
            2000 * 1e6,  // Price: 2000 USDC per WETH
            5 * 1e18     // Amount: 5 WETH (partial fill)
        );
        console.log("Trader2 placed sell order ID:", sellOrderId);
        vm.stopPrank();
        
        // Check order status
        ComplexOrderBook.Order memory buyOrder = orderBook.getOrder(buyOrderId);
        ComplexOrderBook.Order memory sellOrder = orderBook.getOrder(sellOrderId);
        
        console.log("Buy order filled:", buyOrder.filled / 1e18, "WETH");
        console.log("Buy order still active:", buyOrder.isActive);
        console.log("Sell order filled:", sellOrder.filled / 1e18, "WETH");
        console.log("Sell order still active:", sellOrder.isActive);
        
        // Check balances
        console.log("\nFinal balances:");
        console.log("Trader1 WETH:", baseToken.balanceOf(trader1) / 1e18);
        console.log("Trader1 USDC:", quoteToken.balanceOf(trader1) / 1e6);
        console.log("Trader2 WETH:", baseToken.balanceOf(trader2) / 1e18);
        console.log("Trader2 USDC:", quoteToken.balanceOf(trader2) / 1e6);
    }
}
