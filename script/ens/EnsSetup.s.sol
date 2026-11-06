// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IVerifiableFactory, IPermissionedResolver, IUserRegistry, IETHRegistryV2} from "../../test/interfaces/IENSv2.sol";
import {ENSv2Authority, IENSv2Registry} from "../../src/ENSv2Authority.sol";

interface IEACRoot {
    function revokeRootRoles(uint256 roleBitmap, address account) external returns (bool);
}

/// @notice ENSv2 identity layer for the v4 Sepolia stack, on the live ENSv2 contracts.
///   forge script script/ens/EnsSetup.s.sol --rpc-url <sepolia> --broadcast --slow
///
/// Builds on nidhi-dao.eth (registered in v3; its resolver already grants the approver, auditor and guardian roles
/// through Enhanced Access Control) and its UserRegistry of subnames:
///   - ENSv2Authority v4: roles from the DAO name's EAC, grantees resolved per payout chain (ENSIP-11 coin types).
///   - alice.nidhi-dao.eth  on the DAO's shared resolver: gains an Arbitrum Sepolia address beside Base Sepolia.
///   - bob.nidhi-dao.eth    gets HIS OWN PermissionedResolver: the grantee holds the address-setter roles and the
///                          deployer gives its roles up, so only the grantee controls where he is paid.
///   - carol.nidhi-dao.eth  is registered with a short expiry = the grant period. After it expires, resolution fails
///                          closed and the hook refuses to pay her (RecipientMismatch).
/// Writes deployments/ens-v4.json. Uses PRIVATE_KEY (the account that controls nidhi-dao.eth's subregistry/resolver).
contract EnsSetup is Script {
    address constant ENS_ETH_REGISTRY = 0xD4eBcbBdF463C9c45784603Db0dDD499BC44A8B4;
    address constant ENS_VERIFIABLE_FACTORY = 0xDa70306C98E97eCe36F997a21368e53298572991;
    address constant ENS_RESOLVER_IMPL = 0x115eb53F0c60696633855F90b138178Fb40b2b2C;

    uint256 constant ROLE_SET_ADDRESS = 1 << 0; // PermissionedResolverLib
    uint256 constant ROLE_SET_TEXT = 1 << 4;
    uint256 constant ADMIN = 128; // admin bit of a role sits 128 bits higher

    uint64 constant BASE_SEL = 10344971235874465080;
    uint64 constant ARB_SEL = 3478487238524512106;
    uint256 constant BASE_COIN = 0x80000000 | 84532; // ENSIP-11
    uint256 constant ARB_COIN = 0x80000000 | 421614;

    function run() external {
        require(block.chainid == 11155111, "ENSv2 lives on Sepolia");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address dao = vm.addr(pk);
        address wallet = vm.envAddress("GRANTEE_ADDRESS"); // the grantees' payout wallet for this demo
        string memory label = vm.parseJsonString(vm.readFile("deployments/sepolia-ens.json"), ".label");
        string memory subs = vm.readFile("deployments/sepolia-subnames.json");
        address sub = vm.parseJsonAddress(subs, ".subregistry");
        address shared = vm.parseJsonAddress(subs, ".grantsResolver");
        uint64 carolExpiry = uint64(block.timestamp + vm.envOr("CAROL_SECONDS", uint256(2 hours)));

        uint64[] memory sels = new uint64[](2);
        uint256[] memory coins = new uint256[](2);
        (sels[0], coins[0], sels[1], coins[1]) = (BASE_SEL, BASE_COIN, ARB_SEL, ARB_COIN);

        vm.startBroadcast(pk);
        ENSv2Authority auth = new ENSv2Authority(IENSv2Registry(ENS_ETH_REGISTRY), label, sels, coins);

        // alice: shared DAO resolver, now also paid on Arbitrum Sepolia
        IPermissionedResolver(shared).setAddress(_name("alice", label), ARB_COIN, abi.encodePacked(wallet));

        // bob: his own PermissionedResolver. The grantee wallet gets the address-setter role (and its admin);
        // the DAO key sets the first records, then renounces, so the data belongs to the grantee.
        address bobResolver = _ownResolver(dao, wallet, label);
        if (IUserRegistry(sub).getResolver("bob") == address(0)) {
            IUserRegistry(sub).register("bob", wallet, address(0), bobResolver, 0, uint64(block.timestamp + 30 days));
        }
        IPermissionedResolver(bobResolver).setAddress(_name("bob", label), BASE_COIN, abi.encodePacked(wallet));
        IPermissionedResolver(bobResolver).setAddress(_name("bob", label), ARB_COIN, abi.encodePacked(wallet));
        IEACRoot(bobResolver).revokeRootRoles(ROLE_SET_ADDRESS | (ROLE_SET_ADDRESS << ADMIN), dao);

        // carol: an expiring grantee name; the expiry is the grant period
        if (IUserRegistry(sub).getResolver("carol") == address(0)) {
            IUserRegistry(sub).register("carol", dao, address(0), shared, 0, carolExpiry);
        }
        IPermissionedResolver(shared).setAddress(_name("carol", label), BASE_COIN, abi.encodePacked(wallet));
        vm.stopBroadcast();

        // post-conditions through the exact path the hook uses
        require(auth.resolveGrantee("alice", BASE_SEL) == wallet, "alice/base");
        require(auth.resolveGrantee("alice", ARB_SEL) == wallet, "alice/arb");
        require(auth.resolveGrantee("bob", ARB_SEL) == wallet, "bob/arb");
        require(auth.resolveGrantee("carol", BASE_SEL) == wallet, "carol/base");
        require(!IPermissionedResolver(bobResolver).hasRootRoles(ROLE_SET_ADDRESS, dao), "dao still controls bob");
        require(IPermissionedResolver(bobResolver).hasRootRoles(ROLE_SET_ADDRESS, wallet), "bob cannot set his address");

        string memory o = "ensv4";
        vm.serializeAddress(o, "authority", address(auth));
        vm.serializeString(o, "name", string.concat(label, ".eth"));
        vm.serializeAddress(o, "subregistry", sub);
        vm.serializeAddress(o, "sharedResolver", shared);
        vm.serializeAddress(o, "bobResolver", bobResolver);
        vm.serializeUint(o, "carolExpiry", carolExpiry);
        vm.serializeAddress(o, "granteeWallet", wallet);
        string memory json = vm.serializeString(o, "grantees", "alice,bob,carol");
        vm.writeJson(json, "deployments/ens-v4.json");

        console2.log("ENSv2Authority", address(auth));
        console2.log("bob's own resolver", bobResolver);
        console2.log("carol expires at", carolExpiry);
    }

    function _ownResolver(address dao, address owner, string memory label) internal returns (address) {
        IPermissionedResolver.Grant[] memory g = new IPermissionedResolver.Grant[](2);
        g[0] = IPermissionedResolver.Grant(dao, ROLE_SET_ADDRESS | (ROLE_SET_ADDRESS << ADMIN));
        g[1] = IPermissionedResolver.Grant(owner, ROLE_SET_ADDRESS | (ROLE_SET_ADDRESS << ADMIN) | ROLE_SET_TEXT | (ROLE_SET_TEXT << ADMIN));
        return IVerifiableFactory(ENS_VERIFIABLE_FACTORY).deployProxy(
            ENS_RESOLVER_IMPL,
            uint256(keccak256(abi.encode("nidhi.grantee.bob", label, owner))),
            abi.encodeCall(IPermissionedResolver.initialize, (g, new bytes[](0)))
        );
    }

    /// DNS wire format of "<sub>.<label>.eth"
    function _name(string memory s, string memory label) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(bytes(s).length), s, uint8(bytes(label).length), label, uint8(3), "eth", uint8(0));
    }
}
