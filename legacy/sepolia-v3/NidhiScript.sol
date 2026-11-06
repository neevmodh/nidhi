// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

/// @notice Shared addresses (verified on-chain 2026-11-05) and helpers for all Nidhi scripts.
abstract contract NidhiScript is Script {
    // ---------------------------------------------------------------- Ethereum Sepolia (11155111)
    address constant SEP_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant SEP_CCIP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    address constant SEP_LINK = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address constant SEP_BNM = 0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05;
    address constant SEP_WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    uint64 constant SEP_SELECTOR = 16015286601757825753;

    // ---------------------------------------------------------------- Base Sepolia (84532)
    address constant BASE_CCIP_ROUTER = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
    address constant BASE_BNM = 0x88A2d74F47a237a62e7A51cdDa67270CE381555e;
    uint64 constant BASE_SELECTOR = 10344971235874465080;
    uint256 constant BASE_SEPOLIA_COIN_TYPE = 0x80000000 | 84532; // ENSIP-11

    // ---------------------------------------------------------------- ENSv2 on Sepolia (docs.ens.domains/learn/deployments)
    address constant ENS_RESOLVER_IMPL = 0x115eb53F0c60696633855F90b138178Fb40b2b2C;
    address constant ENS_VERIFIABLE_FACTORY = 0xDa70306C98E97eCe36F997a21368e53298572991;
    address constant ENS_ETH_REGISTRAR = 0xf633e7FC17e2bbE0D0965D18ec1821dcB754a3d3;
    address constant ENS_ETH_REGISTRY = 0xD4eBcbBdF463C9c45784603Db0dDD499BC44A8B4;
    address constant ENS_USER_REGISTRY_IMPL = 0x9BD8a88719068D09ecee662f36C0E3856708366a;
    address constant ENS_MOCK_USDC = 0x240b0316Df57887DBBE58b586508b19e633a14aa;

    // ---------------------------------------------------------------- Uniswap v4 periphery (Sepolia)
    address constant SEP_POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // developers.uniswap.org/docs/protocols/v4/deployments (Sepolia)
    address constant SEP_V4_QUOTER = 0x68aFa8b853cAa7a2D40B0F6AEE5C4DbC147C8244;
    address constant SEP_STATE_VIEW = 0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C;
    address constant SEP_RESERVES_LENS = 0x0000001b173C3bbF3984D417d8614E3eed34865B;

    // ---------------------------------------------------------------- Chainlink Automation (Base Sepolia, v2.3)
    address constant BASE_AUTOMATION_REGISTRAR = 0xf28D56F3A707E25B71Ce529a21AF388751E1CF2A;
    address constant BASE_LINK = 0xE4aB69C077896252FAFBD49EFD26B5D171A32410;

    // ---------------------------------------------------------------- misc
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 constant ROLE_SET_TEXT = 1 << 4;
    uint256 constant ROLE_SET_TEXT_ADMIN = ROLE_SET_TEXT << 128;
    uint256 constant APPROVER_RES = uint256(keccak256("nidhi.role.approver"));
    uint256 constant AUDITOR_RES = uint256(keccak256("nidhi.role.auditor"));

    string constant ENS_JSON = "deployments/sepolia-ens.json";
    string constant SEP_JSON = "deployments/sepolia.json";
    string constant BASE_JSON = "deployments/base-sepolia.json";
    string constant SUBNAMES_JSON = "deployments/sepolia-subnames.json";

    function _deployerPk() internal view returns (uint256) {
        return vm.envUint("PRIVATE_KEY");
    }

    function _label() internal view returns (string memory) {
        return vm.envOr("ENS_LABEL", string("nidhi-dao"));
    }

    /// DNS wire format of "<label>.eth"
    function _dnsName(string memory label) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(bytes(label).length), label, uint8(3), "eth", uint8(0));
    }

    /// EIP-137 namehash of "<label>.eth"
    function _namehash(string memory label) internal pure returns (bytes32) {
        bytes32 ethNode = keccak256(abi.encodePacked(bytes32(0), keccak256("eth")));
        return keccak256(abi.encodePacked(ethNode, keccak256(bytes(label))));
    }

    /// DNS wire format of "<sub>.<label>.eth"
    function _dnsSubname(string memory sub, string memory label) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                uint8(bytes(sub).length), sub, uint8(bytes(label).length), label, uint8(3), "eth", uint8(0)
            );
    }

    function _readAddress(string memory path, string memory key) internal view returns (address) {
        return vm.parseJsonAddress(vm.readFile(path), key);
    }

    function _readBytes32(string memory path, string memory key) internal view returns (bytes32) {
        return vm.parseJsonBytes32(vm.readFile(path), key);
    }

    function _requireChain(uint256 id) internal view {
        require(block.chainid == id, "wrong chain for this script");
    }
}
