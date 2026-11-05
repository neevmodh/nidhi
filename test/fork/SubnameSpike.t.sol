// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

interface IVF {
    function deployProxy(address implementation, uint256 salt, bytes calldata data) external returns (address);
}

interface IReg {
    struct Grant {
        address account;
        uint256 roleBitmap;
    }

    function initialize(Grant[] calldata grants) external;
    function register(
        string calldata label,
        address owner,
        address registry,
        address resolver,
        uint256 roleBitmap,
        uint64 expiry
    ) external returns (uint256);
    function getResolver(string calldata label) external view returns (address);
    function getSubregistry(string calldata label) external view returns (address);
    function setSubregistry(uint256 anyId, address registry) external;
}

interface IRes {
    struct Grant {
        address account;
        uint256 roleBitmap;
    }

    function initialize(Grant[] calldata grants, bytes[] calldata calls) external;
    function setAddress(bytes calldata name, uint256 coinType, bytes calldata addr) external;
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory);
}

/// Spike: ENSv2 subnames + on-chain address resolution against the LIVE nidhi-dao.eth on a Sepolia fork.
contract SubnameSpikeTest is Test {
    address constant ETH_REGISTRY = 0xD4eBcbBdF463C9c45784603Db0dDD499BC44A8B4;
    address constant FACTORY = 0xDa70306C98E97eCe36F997a21368e53298572991;
    address constant USER_REGISTRY_IMPL = 0x9BD8a88719068D09ecee662f36C0E3856708366a;
    address constant RESOLVER_IMPL = 0x115eb53F0c60696633855F90b138178Fb40b2b2C;
    address constant DAO = 0x410b6334F7804Ed55e8a1E00D84f6A4a216dB36E; // owner of nidhi-dao.eth
    uint256 constant COIN_BASE_SEPOLIA = 0x80000000 | 84532; // ENSIP-11

    function test_spike_subnameResolution() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        address grantee = makeAddr("alice-wallet");
        vm.startPrank(DAO);

        IReg.Grant[] memory rg = new IReg.Grant[](1);
        rg[0] = IReg.Grant(DAO, (1 << 0) | ((1 << 0) << 128) | (1 << 24) | ((1 << 24) << 128));
        address sub = IVF(FACTORY).deployProxy(USER_REGISTRY_IMPL, 1, abi.encodeCall(IReg.initialize, (rg)));
        IReg(ETH_REGISTRY).setSubregistry(uint256(keccak256("nidhi-dao")), sub);

        IRes.Grant[] memory g = new IRes.Grant[](1);
        g[0] = IRes.Grant(DAO, (1 << 0) | ((1 << 0) << 128) | (1 << 4) | ((1 << 4) << 128));
        address gres = IVF(FACTORY).deployProxy(RESOLVER_IMPL, 2, abi.encodeCall(IRes.initialize, (g, new bytes[](0))));

        IReg(sub).register("alice", DAO, address(0), gres, 0, uint64(block.timestamp + 180 days));
        bytes memory dns = abi.encodePacked(uint8(5), "alice", uint8(9), "nidhi-dao", uint8(3), "eth", uint8(0));
        IRes(gres).setAddress(dns, COIN_BASE_SEPOLIA, abi.encodePacked(grantee));
        vm.stopPrank();

        // Resolution path the hook will use: registry -> subregistry -> resolver -> addr(node, coinType)
        address s = IReg(ETH_REGISTRY).getSubregistry("nidhi-dao");
        address r = IReg(s).getResolver("alice");
        bytes memory out =
            IRes(r).resolve(dns, abi.encodeWithSelector(bytes4(0xf1cb7e06), bytes32(0), COIN_BASE_SEPOLIA));
        bytes memory a = abi.decode(out, (bytes));
        console2.log("subregistry", s);
        console2.log("resolver   ", r);
        assertEq(s, sub);
        assertEq(r, gres);
        assertEq(a.length, 20);
        assertEq(address(bytes20(a)), grantee);
    }
}
