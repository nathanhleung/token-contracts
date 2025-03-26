// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Test} from "forge-std/Test.sol";
import {CalderaAirdrop} from "../src/CalderaAirdrop.sol";
import {CalderaStaking} from "../src/CalderaStaking.sol";
import {CalderaTokenPlaceholder, CalderaToken} from "../src/CalderaToken.sol";

contract CalderaAirdropTest is Test {
    using MessageHashUtils for bytes;
    using ECDSA for bytes32;

    CalderaToken public token;
    CalderaAirdrop public airdrop;
    CalderaStaking public staking;
    address public constant AIRDROP_VAULT = address(0x1);
    bytes32 public constant ADDRESS_CLAIM_MERKLE_ROOT = bytes32(uint256(0x3));
    string public constant ADDRESS_CLAIM_MESSAGE = "I hereby accept the terms of the airdrop and claim.";
    bytes32 public constant GITHUB_CLAIM_MERKLE_ROOT = bytes32(uint256(0x5));
    uint256 public constant START_TIME = 1000;
    uint256 public constant END_TIME = 2000;

    address public githubSigner;
    uint256 public githubSignerPk;

    function setUp() public {
        CalderaTokenPlaceholder unproxiedPlaceholder = new CalderaTokenPlaceholder();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(unproxiedPlaceholder),
            abi.encodeWithSelector(CalderaTokenPlaceholder.initialize.selector, address(this))
        );
        CalderaTokenPlaceholder proxiedPlaceholder = CalderaTokenPlaceholder(address(proxy));

        // Upgrade to the actual token contract
        CalderaToken unproxiedToken = new CalderaToken();
        proxiedPlaceholder.upgradeToAndCall(
            address(unproxiedToken),
            abi.encodeWithSelector(
                CalderaToken.reinitialize.selector, "Test Token", "TEST", AIRDROP_VAULT, 1000 ether, 1000 ether
            )
        );
        token = CalderaToken(address(proxy));

        CalderaStaking unproxiedStaking = new CalderaStaking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(unproxiedStaking), "");
        staking = CalderaStaking(address(stakingProxy));

        (githubSigner, githubSignerPk) = makeAddrAndKey("github_signer");
        CalderaAirdrop.InitializeParams memory params = CalderaAirdrop.InitializeParams({
            initialOwner: address(this),
            airdropVault: AIRDROP_VAULT,
            githubSigner: githubSigner,
            token: address(token),
            staking: address(staking),
            automaticStakingPercent: 0.5e18,
            addressClaimMerkleRoot: ADDRESS_CLAIM_MERKLE_ROOT,
            addressClaimMessage: ADDRESS_CLAIM_MESSAGE,
            githubClaimMerkleRoot: GITHUB_CLAIM_MERKLE_ROOT,
            startTime: START_TIME,
            endTime: END_TIME
        });

        CalderaAirdrop unproxiedAirdrop = new CalderaAirdrop();
        ERC1967Proxy airdropProxy = new ERC1967Proxy(
            address(unproxiedAirdrop), abi.encodeWithSelector(CalderaAirdrop.initialize.selector, params)
        );
        airdrop = CalderaAirdrop(address(airdropProxy));

        staking.initialize(
            address(this),
            address(token),
            AIRDROP_VAULT,
            address(airdrop),
            90 days,
            1 ether,
            7 days,
            block.timestamp + 365 days
        );

        // Approve Airdrop contract to spend tokens from the vault
        vm.prank(AIRDROP_VAULT);
        token.approve(address(airdrop), type(uint256).max);
    }

    function testInitialization() public view {
        assertEq(airdrop.owner(), address(this));
        assertEq(airdrop.airdropVault(), AIRDROP_VAULT);
        assertEq(airdrop.githubSigner(), githubSigner);
        assertEq(address(airdrop.token()), address(token));
        assertEq(airdrop.addressClaimMerkleRoot(), ADDRESS_CLAIM_MERKLE_ROOT);
        assertEq(airdrop.githubClaimMerkleRoot(), GITHUB_CLAIM_MERKLE_ROOT);
        assertEq(airdrop.startTime(), START_TIME);
        assertEq(airdrop.endTime(), END_TIME);
    }

    function testInvalidAirdropVaultInitialization() public {
        CalderaAirdrop newUnproxiedAirdrop = new CalderaAirdrop();
        (address newGithubSigner,) = makeAddrAndKey("github_signer");

        CalderaAirdrop.InitializeParams memory params = CalderaAirdrop.InitializeParams({
            initialOwner: address(this),
            airdropVault: address(0),
            githubSigner: newGithubSigner,
            token: address(token),
            staking: address(staking),
            automaticStakingPercent: 0.5e18,
            addressClaimMerkleRoot: ADDRESS_CLAIM_MERKLE_ROOT,
            addressClaimMessage: ADDRESS_CLAIM_MESSAGE,
            githubClaimMerkleRoot: GITHUB_CLAIM_MERKLE_ROOT,
            startTime: START_TIME,
            endTime: END_TIME
        });

        vm.expectRevert(CalderaAirdrop.InvalidAirdropVault.selector);
        new ERC1967Proxy(
            address(newUnproxiedAirdrop), abi.encodeWithSelector(CalderaAirdrop.initialize.selector, params)
        );
    }

    function testInvalidGithubSignerInitialization() public {
        CalderaAirdrop newUnproxiedAirdrop = new CalderaAirdrop();

        CalderaAirdrop.InitializeParams memory params = CalderaAirdrop.InitializeParams({
            initialOwner: address(this),
            airdropVault: AIRDROP_VAULT,
            githubSigner: address(0),
            token: address(token),
            staking: address(staking),
            automaticStakingPercent: 0.5e18,
            addressClaimMerkleRoot: ADDRESS_CLAIM_MERKLE_ROOT,
            addressClaimMessage: ADDRESS_CLAIM_MESSAGE,
            githubClaimMerkleRoot: GITHUB_CLAIM_MERKLE_ROOT,
            startTime: START_TIME,
            endTime: END_TIME
        });

        vm.expectRevert(CalderaAirdrop.InvalidGithubSigner.selector);
        new ERC1967Proxy(
            address(newUnproxiedAirdrop), abi.encodeWithSelector(CalderaAirdrop.initialize.selector, params)
        );
    }

    function testInvalidTokenInitialization() public {
        CalderaAirdrop newUnproxiedAirdrop = new CalderaAirdrop();
        (address newGithubSigner,) = makeAddrAndKey("github_signer");

        CalderaAirdrop.InitializeParams memory params = CalderaAirdrop.InitializeParams({
            initialOwner: address(this),
            airdropVault: AIRDROP_VAULT,
            githubSigner: newGithubSigner,
            token: address(0),
            staking: address(staking),
            automaticStakingPercent: 0.5e18,
            addressClaimMerkleRoot: ADDRESS_CLAIM_MERKLE_ROOT,
            addressClaimMessage: ADDRESS_CLAIM_MESSAGE,
            githubClaimMerkleRoot: GITHUB_CLAIM_MERKLE_ROOT,
            startTime: START_TIME,
            endTime: END_TIME
        });

        vm.expectRevert(CalderaAirdrop.InvalidToken.selector);
        new ERC1967Proxy(
            address(newUnproxiedAirdrop), abi.encodeWithSelector(CalderaAirdrop.initialize.selector, params)
        );
    }

    function testInvalidClaimPeriodInitialization() public {
        CalderaAirdrop newUnproxiedAirdrop = new CalderaAirdrop();
        (address newGithubSigner,) = makeAddrAndKey("github_signer");

        CalderaAirdrop.InitializeParams memory params = CalderaAirdrop.InitializeParams({
            initialOwner: address(this),
            airdropVault: AIRDROP_VAULT,
            githubSigner: newGithubSigner,
            token: address(token),
            staking: address(staking),
            automaticStakingPercent: 0.5e18,
            addressClaimMerkleRoot: ADDRESS_CLAIM_MERKLE_ROOT,
            addressClaimMessage: ADDRESS_CLAIM_MESSAGE,
            githubClaimMerkleRoot: GITHUB_CLAIM_MERKLE_ROOT,
            startTime: END_TIME,
            endTime: START_TIME
        });

        vm.expectRevert(CalderaAirdrop.InvalidClaimPeriod.selector);
        new ERC1967Proxy(
            address(newUnproxiedAirdrop), abi.encodeWithSelector(CalderaAirdrop.initialize.selector, params)
        );
    }

    function testPauseUnpause() public {
        airdrop.pause();
        assertTrue(airdrop.paused());

        vm.expectRevert(Pausable.EnforcedPause.selector);
        airdrop.addressClaim(100 ether, new bytes32[](0), new bytes(0));

        airdrop.unpause();
        assertFalse(airdrop.paused());
    }

    function testSetAirdropVault() public {
        address newVault = address(0x2);
        airdrop.setAirdropVault(newVault);
        assertEq(airdrop.airdropVault(), newVault);
    }

    function testSetGithubSigner() public {
        address newSigner = address(0x123);
        airdrop.setGithubSigner(newSigner);
        assertEq(airdrop.githubSigner(), newSigner);
    }

    function testSetStartTime() public {
        airdrop.setStartTime(START_TIME + 1);
        assertEq(airdrop.startTime(), START_TIME + 1);
    }

    function testSetEndTime() public {
        airdrop.setEndTime(END_TIME + 1);
        assertEq(airdrop.endTime(), END_TIME + 1);
    }

    function testSetStartTimeTooLate() public {
        vm.expectRevert(CalderaAirdrop.StartTimeTooLate.selector);
        airdrop.setStartTime(END_TIME + 1);
    }

    function testSetEndTimeTooEarly() public {
        vm.expectRevert(CalderaAirdrop.EndTimeTooEarly.selector);
        airdrop.setEndTime(START_TIME - 1);
    }

    function testBlockUnblock() public {
        address user = address(0x8);
        address[] memory users = new address[](1);
        users[0] = user;
        airdrop.updateBlocklist(users, true);
        assertTrue(airdrop.blocked(user));

        vm.warp(START_TIME + 1);
        vm.prank(user);
        vm.expectRevert(CalderaAirdrop.BlockedAddress.selector);
        airdrop.addressClaim(100 ether, new bytes32[](0), new bytes(0));

        airdrop.updateBlocklist(users, false);
        assertFalse(airdrop.blocked(user));
    }

    function testSetAddressClaimMessage() public {
        string memory newMessage = "New claim message";
        airdrop.setAddressClaimMessage(newMessage);
        assertEq(airdrop.addressClaimMessage(), newMessage);
    }

    function testSetAddressClaimMerkleRoot() public {
        bytes32 newRoot = bytes32(uint256(0x9));
        airdrop.setAddressClaimMerkleRoot(newRoot);
        assertEq(airdrop.addressClaimMerkleRoot(), newRoot);
    }

    function testGetGithubClaimVerificationMessage() public view {
        address testAddress = address(0x123);
        string memory githubUsername = "testuser";
        string memory expectedMessage = string.concat(
            "This attests that the following association between (sender_address,github_username) has been verified: ",
            "(",
            Strings.toHexString(testAddress),
            ",",
            githubUsername,
            ")"
        );
        string memory actualMessage = airdrop.getGithubClaimVerificationMessage(testAddress, githubUsername);
        assertEq(actualMessage, expectedMessage);
    }

    function testSetGithubClaimMerkleRoot() public {
        bytes32 newRoot = bytes32(uint256(0xB));
        airdrop.setGithubClaimMerkleRoot(newRoot);
        assertEq(airdrop.githubClaimMerkleRoot(), newRoot);
    }

    function _getAddressClaimProof() internal pure returns (bytes32[] memory) {
        // Proof generated from `pnpm merkle` in `packages/era/scripts`
        bytes32[] memory proof = new bytes32[](3);
        proof[0] = 0x5c5e24c4b2b637cd87ab36e8d558208882407c5e6a9af924fed3e39f2c42c9a6;
        proof[1] = 0xeb62004dbac6d17175b2b626b47f8fa8d13a057fdfa3abcdd48a2202a794d9b1;
        proof[2] = 0x9994a3b84c56de92564f71ba60af9452450fbc91662b14ea258d57e9747c4212;
        return proof;
    }

    function testValidAddressClaim() public {
        // Default hardhat private key
        uint256 claimerPk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address claimer = vm.addr(claimerPk);
        uint256 amount = 5 ether;

        airdrop.setAddressClaimMerkleRoot(0x306390d42be12e64dbdc246a007cf79d156c75bd7148cf8d03ae283603bc8506);
        bytes32[] memory proof = _getAddressClaimProof();

        vm.warp(START_TIME + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(claimerPk, bytes(ADDRESS_CLAIM_MESSAGE).toEthSignedMessageHash());
        bytes memory signature = abi.encodePacked(r, s, v);
        vm.prank(claimer);
        airdrop.addressClaim(amount, proof, signature);

        assertEq(token.balanceOf(claimer), 2.5 ether);
        assertEq(CalderaStaking(address(staking)).getUserTotalStakeAmount(claimer), 2.5 ether);
    }

    function testInvalidAddressClaim() public {
        // Default hardhat private key
        uint256 claimerPk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address claimer = vm.addr(claimerPk);
        uint256 amount = 5 ether;

        airdrop.setAddressClaimMerkleRoot(0x0);
        bytes32[] memory proof = _getAddressClaimProof();

        vm.warp(START_TIME + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(claimerPk, bytes(ADDRESS_CLAIM_MESSAGE).toEthSignedMessageHash());
        bytes memory signature = abi.encodePacked(r, s, v);
        vm.prank(claimer);
        vm.expectRevert(CalderaAirdrop.InvalidMerkleProof.selector);
        airdrop.addressClaim(amount, proof, signature);
    }

    function testInvalidAddressSignatureClaim() public {
        uint256 claimerPk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address claimer = vm.addr(claimerPk);
        uint256 amount = 5 ether;
        bytes32[] memory proof = _getAddressClaimProof();

        // Generate invalid signature
        (, uint256 randomSignerPk) = makeAddrAndKey("random_signer");
        (uint8 v1, bytes32 r1, bytes32 s1) =
            vm.sign(randomSignerPk, bytes(ADDRESS_CLAIM_MESSAGE).toEthSignedMessageHash());
        bytes memory invalidAddressSignature = abi.encodePacked(r1, s1, v1);

        vm.prank(claimer);
        vm.warp(START_TIME + 1);
        vm.expectRevert(CalderaAirdrop.InvalidAddressSignature.selector);
        airdrop.addressClaim(amount, proof, invalidAddressSignature);
    }

    function testClaimWithBlockedAddress() public {
        uint256 claimerPk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address claimer = vm.addr(claimerPk);
        uint256 amount = 5 ether;
        bytes32[] memory proof = _getAddressClaimProof();

        bytes memory signature = _generateAddressSignature(claimerPk);

        // Block the address
        address[] memory blockedAddresses = new address[](1);
        blockedAddresses[0] = claimer;
        airdrop.updateBlocklist(blockedAddresses, true);

        vm.prank(claimer);
        vm.warp(START_TIME + 1);
        vm.expectRevert(CalderaAirdrop.BlockedAddress.selector);
        airdrop.addressClaim(amount, proof, signature);
    }

    function testInvalidGithubClaim() public {
        (address claimer, uint256 claimerPk) = makeAddrAndKey("claimer");

        string memory githubUsername = "testuser";
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bytes32(uint256(0x7));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(claimerPk, bytes(ADDRESS_CLAIM_MESSAGE).toEthSignedMessageHash());
        bytes memory addressSignature = abi.encodePacked(r1, s1, v1);

        string memory githubOwnershipVerificationMessage =
            airdrop.getGithubClaimVerificationMessage(claimer, githubUsername);
        (uint8 v2, bytes32 r2, bytes32 s2) =
            vm.sign(githubSignerPk, bytes(githubOwnershipVerificationMessage).toEthSignedMessageHash());
        bytes memory githubOwnershipVerificationSignature = abi.encodePacked(r2, s2, v2);

        vm.prank(claimer);
        vm.warp(START_TIME + 1);
        vm.expectRevert(CalderaAirdrop.InvalidMerkleProof.selector);
        airdrop.githubClaim(githubUsername, 100 ether, proof, addressSignature, githubOwnershipVerificationSignature);
    }

    function testInvalidGithubOwnershipVerificationSignatureClaim() public {
        (address claimer, uint256 claimerPk) = makeAddrAndKey("claimer");
        uint256 amount = 8 ether;
        string memory githubUsername = "vbuterin";

        // Root generated from `pnpm merkle` in `packages/era/scripts`
        airdrop.setGithubClaimMerkleRoot(0x68cb01563116d6ddc2d252c4bdf203043d6a574bb4e160c610d08b876d7d2d1b);

        bytes32[] memory proof = _getGithubClaimProof();
        bytes memory addressSignature = _generateAddressSignature(claimerPk);

        // Generate invalid signature
        (, uint256 randomSignerPk) = makeAddrAndKey("random_signer");
        string memory githubOwnershipVerificationMessage =
            airdrop.getGithubClaimVerificationMessage(claimer, githubUsername);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(randomSignerPk, bytes(githubOwnershipVerificationMessage).toEthSignedMessageHash());
        bytes memory invalidGithubOwnershipVerificationSignature = abi.encodePacked(r, s, v);

        vm.prank(claimer);
        vm.warp(START_TIME + 1);
        vm.expectRevert(CalderaAirdrop.InvalidGithubOwnershipVerificationSignature.selector);
        airdrop.githubClaim(
            githubUsername, amount, proof, addressSignature, invalidGithubOwnershipVerificationSignature
        );
    }

    function _getGithubClaimProof() internal pure returns (bytes32[] memory) {
        // Proof generated from `pnpm merkle` in `packages/era/scripts`
        bytes32[] memory proof = new bytes32[](3);
        proof[0] = 0xd287a5a4e06d1e1480795f50266ee2ead36f8f56a9a972b189d4a56334d7db4c;
        proof[1] = 0xd1b2c1951bcf58de677de3f1a459ba11ac18a41021b9b885d80251f4a6b254eb;
        proof[2] = 0x23e5343c081aaab789481f9ffd57621c983d40bd9846d211bdc3857564639e5d;
        return proof;
    }

    function testValidGithubClaim() public {
        (address claimer, uint256 claimerPk) = makeAddrAndKey("claimer");
        uint256 amount = 8 ether;
        string memory githubUsername = "vbuterin";

        // Root generated from `pnpm merkle` in `packages/era/scripts`
        airdrop.setGithubClaimMerkleRoot(0x68cb01563116d6ddc2d252c4bdf203043d6a574bb4e160c610d08b876d7d2d1b);

        bytes32[] memory proof = _getGithubClaimProof();
        bytes memory addressSignature = _generateAddressSignature(claimerPk);
        bytes memory githubOwnershipVerificationSignature = _generateGithubSignature(claimer, githubUsername);

        vm.prank(claimer);
        vm.warp(START_TIME + 1);
        airdrop.githubClaim(githubUsername, amount, proof, addressSignature, githubOwnershipVerificationSignature);

        assertEq(token.balanceOf(claimer), amount / 2);
        assertEq(CalderaStaking(address(staking)).getUserTotalStakeAmount(claimer), amount / 2);
    }

    function testCombinedClaim() public {
        uint256 claimerPk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address claimer = vm.addr(claimerPk);
        uint256 addressAmount = 5 ether;
        string memory githubUsername = "vbuterin";
        uint256 githubAmount = 8 ether;

        (bytes32[] memory addressProof, bytes32[] memory githubProof) = _setupCombinedClaimProofs();
        // Roots generated from `pnpm merkle` in `packages/era/scripts`
        airdrop.setAddressClaimMerkleRoot(0x306390d42be12e64dbdc246a007cf79d156c75bd7148cf8d03ae283603bc8506);
        airdrop.setGithubClaimMerkleRoot(0x68cb01563116d6ddc2d252c4bdf203043d6a574bb4e160c610d08b876d7d2d1b);

        bytes memory addressSignature = _generateAddressSignature(claimerPk);
        bytes memory githubOwnershipVerificationSignature = _generateGithubSignature(claimer, githubUsername);

        vm.prank(claimer);
        vm.warp(START_TIME + 1);
        airdrop.combinedClaim(
            addressAmount,
            addressProof,
            addressSignature,
            githubUsername,
            githubAmount,
            githubProof,
            githubOwnershipVerificationSignature
        );

        uint256 totalAmount = addressAmount + githubAmount;
        assertEq(token.balanceOf(claimer), totalAmount / 2);
        assertEq(CalderaStaking(address(staking)).getUserTotalStakeAmount(claimer), totalAmount / 2);
    }

    function _setupCombinedClaimProofs() internal pure returns (bytes32[] memory, bytes32[] memory) {
        bytes32[] memory addressProof = _getAddressClaimProof();
        bytes32[] memory githubProof = _getGithubClaimProof();
        return (addressProof, githubProof);
    }

    function _generateAddressSignature(uint256 claimerPk) internal pure returns (bytes memory) {
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(claimerPk, bytes(ADDRESS_CLAIM_MESSAGE).toEthSignedMessageHash());
        return abi.encodePacked(r1, s1, v1);
    }

    function _generateGithubSignature(address claimer, string memory githubUsername)
        internal
        view
        returns (bytes memory)
    {
        string memory githubOwnershipVerificationMessage =
            airdrop.getGithubClaimVerificationMessage(claimer, githubUsername);
        (uint8 v2, bytes32 r2, bytes32 s2) =
            vm.sign(githubSignerPk, bytes(githubOwnershipVerificationMessage).toEthSignedMessageHash());
        return abi.encodePacked(r2, s2, v2);
    }

    function testClaimOutsideTimeRange() public {
        (address claimer, uint256 claimerPk) = makeAddrAndKey("claimer");
        uint256 amount = 100 ether;
        bytes32[] memory proof = new bytes32[](1);

        // Generate signature
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(claimerPk, bytes(ADDRESS_CLAIM_MESSAGE).toEthSignedMessageHash());
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.warp(START_TIME - 1);
        vm.prank(claimer);
        vm.expectRevert(CalderaAirdrop.ClaimPeriodNotStarted.selector);
        airdrop.addressClaim(amount, proof, signature);

        vm.warp(END_TIME + 1);
        vm.prank(claimer);
        vm.expectRevert(CalderaAirdrop.ClaimPeriodEnded.selector);
        airdrop.addressClaim(amount, proof, signature);
    }

    function testDoubleAddressClaim() public {
        uint256 claimerPk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address claimer = vm.addr(claimerPk);
        uint256 amount = 5 ether;

        // Root generated from `pnpm merkle` in `packages/era/scripts`
        airdrop.setAddressClaimMerkleRoot(0x306390d42be12e64dbdc246a007cf79d156c75bd7148cf8d03ae283603bc8506);
        bytes32[] memory proof = _getAddressClaimProof();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(claimerPk, bytes(ADDRESS_CLAIM_MESSAGE).toEthSignedMessageHash());
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.warp(START_TIME + 1);
        vm.prank(claimer);
        airdrop.addressClaim(amount, proof, signature);

        vm.expectRevert(CalderaAirdrop.AlreadyClaimed.selector);
        vm.prank(claimer);
        airdrop.addressClaim(amount, proof, signature);
    }

    function testDoubleGithubClaim() public {
        airdrop.setGithubClaimMerkleRoot(0x68cb01563116d6ddc2d252c4bdf203043d6a574bb4e160c610d08b876d7d2d1b);
        (address claimer, uint256 claimerPk) = makeAddrAndKey("claimer");

        string memory githubUsername = "vbuterin";
        uint256 githubAmount = 8 ether;
        bytes32[] memory githubProof = _getGithubClaimProof();

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(claimerPk, bytes(ADDRESS_CLAIM_MESSAGE).toEthSignedMessageHash());
        bytes memory addressSignature = abi.encodePacked(r1, s1, v1);

        string memory githubOwnershipVerificationMessage =
            airdrop.getGithubClaimVerificationMessage(claimer, githubUsername);
        (uint8 v2, bytes32 r2, bytes32 s2) =
            vm.sign(githubSignerPk, bytes(githubOwnershipVerificationMessage).toEthSignedMessageHash());
        bytes memory githubOwnershipVerificationSignature = abi.encodePacked(r2, s2, v2);

        vm.prank(claimer);
        vm.warp(START_TIME + 1);
        airdrop.githubClaim(
            githubUsername, githubAmount, githubProof, addressSignature, githubOwnershipVerificationSignature
        );

        vm.prank(claimer);
        vm.expectRevert(CalderaAirdrop.AlreadyClaimed.selector);
        airdrop.githubClaim(
            githubUsername, githubAmount, githubProof, addressSignature, githubOwnershipVerificationSignature
        );
    }

    function testCombinedClaimPartiallyAlreadyClaimed() public {
        uint256 claimerPk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address claimer = vm.addr(claimerPk);
        uint256 addressAmount = 5 ether;
        string memory githubUsername = "vbuterin";
        uint256 githubAmount = 8 ether;

        (bytes32[] memory addressProof, bytes32[] memory githubProof) = _setupCombinedClaimProofs();
        // Roots generated from `pnpm merkle` in `packages/era/scripts`
        airdrop.setAddressClaimMerkleRoot(0x306390d42be12e64dbdc246a007cf79d156c75bd7148cf8d03ae283603bc8506);
        airdrop.setGithubClaimMerkleRoot(0x68cb01563116d6ddc2d252c4bdf203043d6a574bb4e160c610d08b876d7d2d1b);

        bytes memory addressSignature = _generateAddressSignature(claimerPk);
        bytes memory githubOwnershipVerificationSignature = _generateGithubSignature(claimer, githubUsername);

        // First, claim the address portion
        vm.prank(claimer);
        vm.warp(START_TIME + 1);
        airdrop.addressClaim(addressAmount, addressProof, addressSignature);

        // Now try to do a combined claim
        vm.prank(claimer);
        vm.expectRevert(CalderaAirdrop.AlreadyClaimed.selector);
        airdrop.combinedClaim(
            addressAmount,
            addressProof,
            addressSignature,
            githubUsername,
            githubAmount,
            githubProof,
            githubOwnershipVerificationSignature
        );
    }
}
