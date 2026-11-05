// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IGrantAuthority} from "./interfaces/IGrantAuthority.sol";

/// @dev ENSv2 ETHRegistry (PermissionedRegistry). Returns address(0) for unregistered or expired names.
interface IENSv2Registry {
    function getResolver(string calldata label) external view returns (address);
    function getSubregistry(string calldata label) external view returns (address);
}

/// @dev ENSIP-10 extended resolver (implemented by the ENSv2 PermissionedResolver).
interface IExtendedResolver {
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory);
}

/// @dev ENSv2 EnhancedAccessControl. hasRoles() checks ROOT_RESOURCE | resource.
interface IEnhancedAccessControl {
    function hasRoles(uint256 resource, uint256 roleBitmap, address account) external view returns (bool);
}

/// @title ENSv2Authority
/// @notice Nidhi's on-chain firewall, driven entirely by the DAO's ENSv2 name.
///
///   1. Name -> resolver: the resolver is looked up from the ENSv2 registry on every check, so permissions follow
///      whatever resolver the DAO's name currently points to. Nothing about the DAO's permissions is hard-coded here.
///      If the name is unregistered or expires, getResolver() returns address(0) and ALL payouts freeze.
///   2. Resolver -> role: a Nidhi role is ENSv2 Enhanced Access Control permission ROLE_SET_TEXT on the text-record
///      resource for that role's key, exactly as the deployed PermissionedResolver checks setText():
///        resource = keccak256(bytes(key))        (PermissionedResolverLib.resource(string))
///      EAC hasRoles() also honours ROOT_RESOURCE grants (permission over every key).
///
///   The DAO grants a role with   resolver.grantSetterRoles(abi.encodeCall(setText, (name, key, "")), account)
///   and revokes it with          resolver.revokeRoles(keccak256(bytes(key)), ROLE_SET_TEXT, account).
///   Revocation takes effect on the very next swap - no redeploy, no Nidhi admin involved.
///
/// @dev Matches the PermissionedResolver deployed on Sepolia at 0x115eb53F0c60696633855F90b138178Fb40b2b2C
///      (Sourcify exact match). The verified source is the reference for the resource derivation above.
contract ENSv2Authority is IGrantAuthority {
    /// PermissionedResolverLib.ROLE_SET_TEXT
    uint256 public constant ROLE_SET_TEXT = 1 << 4;

    bytes32 public constant APPROVER = keccak256("nidhi.role.approver");
    bytes32 public constant AUDITOR = keccak256("nidhi.role.auditor");
    bytes32 public constant GUARDIAN = keccak256("nidhi.role.guardian");

    /// ENS text-record keys whose setter permission encodes each Nidhi role.
    string public constant APPROVER_KEY = "nidhi.role.approver";
    string public constant AUDITOR_KEY = "nidhi.role.auditor";
    string public constant GUARDIAN_KEY = "nidhi.role.guardian";

    /// IAddressResolver.addr(bytes32,uint256)
    bytes4 internal constant ADDR_COIN_SELECTOR = 0xf1cb7e06;

    IENSv2Registry public immutable registry;
    /// @notice ENSIP-11 coin type of the payout chain (e.g. 0x80000000 | 84532 for Base Sepolia).
    uint256 public immutable granteeCoinType;
    /// @notice The DAO's label under the registry, e.g. "nidhi-dao" for nidhi-dao.eth.
    string public label;

    error BadConfig();

    constructor(IENSv2Registry registry_, string memory label_, uint256 granteeCoinType_) {
        if (address(registry_) == address(0) || bytes(label_).length == 0) revert BadConfig();
        registry = registry_;
        label = label_;
        granteeCoinType = granteeCoinType_;
    }

    /// @notice The resolver the DAO's name points to right now (address(0) if the name is unset or expired).
    function currentResolver() public view returns (address) {
        return registry.getResolver(label);
    }

    /// @notice EAC resource id for a Nidhi role (= PermissionedResolverLib.resource(key)).
    function resourceOf(bytes32 role) public pure returns (uint256) {
        if (role == APPROVER) return uint256(keccak256(bytes(APPROVER_KEY)));
        if (role == AUDITOR) return uint256(keccak256(bytes(AUDITOR_KEY)));
        if (role == GUARDIAN) return uint256(keccak256(bytes(GUARDIAN_KEY)));
        return 0;
    }

    /// @inheritdoc IGrantAuthority
    function isAuthorized(bytes32 role, address account) external view returns (bool) {
        uint256 resource = resourceOf(role);
        if (resource == 0) return false;
        address resolver = currentResolver();
        if (resolver == address(0)) return false; // name unregistered/expired: fail closed
        return IEnhancedAccessControl(resolver).hasRoles(resource, ROLE_SET_TEXT, account);
    }

    /// @notice Resolve the grantee subname `<granteeLabel>.<label>.eth` to its payout-chain address:
    ///         registry.getSubregistry(dao) -> subregistry.getResolver(grantee) -> resolver.resolve(name, addr(node, coin)).
    ///         Any missing link (no subregistry, expired subname, no record, malformed record) returns address(0).
    function resolveGrantee(string calldata granteeLabel) external view returns (address) {
        if (bytes(granteeLabel).length == 0 || bytes(granteeLabel).length > 63) return address(0);
        address sub = registry.getSubregistry(label);
        if (sub == address(0)) return address(0);
        address resolver = address(0);
        try IENSv2Registry(sub).getResolver(granteeLabel) returns (address r) {
            resolver = r;
        } catch {
            return address(0);
        }
        if (resolver == address(0)) return address(0);
        bytes memory name = granteeName(granteeLabel);
        try IExtendedResolver(resolver)
            .resolve(name, abi.encodeWithSelector(ADDR_COIN_SELECTOR, bytes32(0), granteeCoinType)) returns (
            bytes memory out
        ) {
            if (out.length < 64) return address(0);
            bytes memory a = abi.decode(out, (bytes));
            if (a.length != 20) return address(0);
            return address(bytes20(a));
        } catch {
            return address(0);
        }
    }

    /// @notice DNS wire encoding of `<granteeLabel>.<label>.eth`.
    function granteeName(string calldata granteeLabel) public view returns (bytes memory) {
        return abi.encodePacked(
            uint8(bytes(granteeLabel).length),
            granteeLabel,
            uint8(bytes(label).length),
            label,
            uint8(3),
            "eth",
            uint8(0)
        );
    }
}
