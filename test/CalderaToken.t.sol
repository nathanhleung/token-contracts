// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Test} from "forge-std/Test.sol";
import {CalderaTokenPlaceholder, CalderaToken} from "../src/CalderaToken.sol";

contract CalderaTokenTest is Test {
    CalderaToken public token;
    address public constant AIRDROP_VAULT = address(0x1);

    function setUp() public {
        CalderaTokenPlaceholder unproxiedPlaceholder = new CalderaTokenPlaceholder();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(unproxiedPlaceholder),
            abi.encodeWithSelector(CalderaTokenPlaceholder.initialize.selector, address(this))
        );
        CalderaTokenPlaceholder proxiedPlaceholder = CalderaTokenPlaceholder(address(proxy));

        // Second argument sets `tx.origin`
        vm.startPrank(address(this), address(this));

        // Upgrade to the actual token contract
        CalderaToken unproxiedToken = new CalderaToken();
        proxiedPlaceholder.upgradeToAndCall(
            address(unproxiedToken),
            abi.encodeWithSelector(
                CalderaToken.reinitialize.selector, "Caldera", "ERA", AIRDROP_VAULT, 1 ether, 2 ether
            )
        );
        token = CalderaToken(address(proxy));
        vm.stopPrank();
    }

    function testInitialSupply() public view {
        assertEq(token.balanceOf(AIRDROP_VAULT), 1 ether, "Airdrop vault should have 1 ether");
        assertEq(token.balanceOf(address(this)), 2 ether, "Deployer should have 2 ether");
        assertEq(token.totalSupply(), 3 ether, "Initial supply should be 3");
    }

    function testInitializeWithExcessiveSupply() public {
        CalderaTokenPlaceholder unproxiedPlaceholder = new CalderaTokenPlaceholder();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(unproxiedPlaceholder),
            abi.encodeWithSelector(CalderaTokenPlaceholder.initialize.selector, address(this))
        );
        CalderaTokenPlaceholder proxiedPlaceholder = CalderaTokenPlaceholder(address(proxy));

        // Upgrade to the actual token contract, but with an excessive supply
        CalderaToken unproxiedToken = new CalderaToken();
        vm.expectRevert(CalderaToken.SupplyCapExceeded.selector);
        proxiedPlaceholder.upgradeToAndCall(
            address(unproxiedToken),
            abi.encodeWithSelector(
                CalderaToken.reinitialize.selector, "Caldera", "ERA", address(this), 10_000_000_001 ether, 0 ether
            )
        );

        // Upgrade to the actual token contract, but with an excessive supply
        vm.expectRevert(CalderaToken.SupplyCapExceeded.selector);
        proxiedPlaceholder.upgradeToAndCall(
            address(unproxiedToken),
            abi.encodeWithSelector(
                CalderaToken.reinitialize.selector, "Caldera", "ERA", address(this), 10_000_000_000 ether, 1 ether
            )
        );
    }

    function testInitialOwner() public view {
        assertEq(token.owner(), address(this), "Initial owner should be the Tests contract");
    }

    function testName() public view {
        assertEq(token.name(), "Caldera", "Token name should be Caldera");
    }

    function testSymbol() public view {
        assertEq(token.symbol(), "ERA", "Token symbol should be ERA");
    }

    function testMintInterval() public view {
        assertEq(token.MINIMUM_MINT_INTERVAL(), 365 days, "Minimum mint interval should be 365 days");
    }

    function testMintCap() public view {
        assertEq(token.mintCapBips(), 500, "Mint cap should be 500 bips (5%)");
    }

    function testMaxSupply() public view {
        assertEq(token.MAX_SUPPLY(), 10_000_000_000 ether, "Max supply should be 10 billion");
    }

    function testMaxSupplyCap() public {
        // This gets us right below 10 billion
        for (uint256 i = 0; i < 449; i++) {
            vm.warp(block.timestamp + 365 days);
            uint256 currentSupply = token.totalSupply();
            uint256 amountToMint = (currentSupply * token.mintCapBips()) / 10000;
            token.mint(address(this), amountToMint);
        }

        vm.warp(block.timestamp + 365 days);
        assert(token.totalSupply() < token.MAX_SUPPLY());
        token.mint(address(this), token.MAX_SUPPLY() - token.totalSupply());

        vm.warp(block.timestamp + 365 days);
        assertEq(token.totalSupply(), token.MAX_SUPPLY());

        vm.expectRevert(CalderaToken.SupplyCapExceeded.selector);
        token.mint(address(this), 1);
    }

    function testMint() public {
        uint256 initialSupply = token.totalSupply();
        vm.warp(block.timestamp + 365 days);
        token.mint(address(this), 0.05 ether);
        assertEq(token.totalSupply(), initialSupply + 0.05 ether, "Total supply should increase after minting");
    }

    function testMintFailBeforeInterval() public {
        vm.expectRevert(CalderaToken.MintPeriodNotStarted.selector);
        token.mint(address(this), 50000000000000000);
    }

    function testMintFailExceedsCap() public {
        vm.warp(block.timestamp + 365 days);
        uint256 maxMintAmount = token.totalSupply() / 20;

        vm.expectRevert(CalderaToken.MintCapExceeded.selector);
        token.mint(address(this), maxMintAmount + 1);
    }

    function testMintFailNonOwner() public {
        vm.warp(block.timestamp + 365 days);
        vm.prank(address(0x1));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0x1)));
        token.mint(address(this), 0.05 ether);
    }

    function testLowerMintCap() public {
        vm.warp(block.timestamp + 365 days);
        uint256 maxMintAmount = token.totalSupply() / 20;
        token.mint(address(this), maxMintAmount);
        token.lowerMintCap(250);
        vm.expectRevert(CalderaToken.MintCapExceeded.selector);
        token.mint(address(this), maxMintAmount);
    }

    function testLowerMintCapTooHigh() public {
        vm.warp(block.timestamp + 365 days);
        token.mint(address(this), 0.05 ether);
        vm.expectRevert(CalderaToken.MintCapTooHigh.selector);
        token.lowerMintCap(501); // Attempt to increase the mint cap
    }

    function testNonces() public view {
        assertEq(token.nonces(address(this)), 0);
    }

    function testUpgradeFailNonOwner() public {
        vm.prank(address(0x1));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0x1)));
        token.upgradeToAndCall(address(0x2), "");
    }

    function testReinitializeTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.reinitialize("Test Token", "TEST", address(this), 1000 ether, 1000 ether);
    }
}
