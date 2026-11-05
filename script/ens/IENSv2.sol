// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Minimal interfaces for ENSv2 Sepolia contracts (ensdomains/contracts-v2).
interface IVerifiableFactory {
    function deployProxy(address implementation, uint256 salt, bytes calldata data) external returns (address);
}

/// Live Sepolia PermissionedResolver (Sourcify exact match at 0x115eb53F0c60696633855F90b138178Fb40b2b2C).
interface IPermissionedResolver {
    struct Grant {
        address account;
        uint256 roleBitmap;
    }

    function initialize(Grant[] calldata grants, bytes[] calldata calls) external;
    function grantSetterRoles(bytes calldata setter, address account) external returns (bool);
    function revokeRoles(uint256 resource, uint256 roleBitmap, address account) external returns (bool);
    function setText(bytes calldata name, string calldata key, string calldata value) external;
    function setAddress(bytes calldata name, uint256 coinType, bytes calldata addressBytes) external;
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory);
    function text(bytes32 node, string calldata key) external view returns (string memory);
    function hasRoles(uint256 resource, uint256 roleBitmap, address account) external view returns (bool);
    function hasRootRoles(uint256 roleBitmap, address account) external view returns (bool);
}

interface IETHRegistrar {
    function isAvailable(string calldata label) external view returns (bool);
    function commit(bytes32 commitment) external;
    function makeCommitment(
        string calldata label,
        address owner,
        bytes32 secret,
        address subregistry,
        address resolver,
        uint64 duration,
        bytes32 referrer
    ) external pure returns (bytes32);
    function register(
        string calldata label,
        address owner,
        bytes32 secret,
        address subregistry,
        address resolver,
        uint64 duration,
        address paymentToken,
        bytes32 referrer
    ) external returns (uint256 tokenId);
    function getRegisterPrice(string calldata label, uint64 duration, address paymentToken)
        external
        view
        returns (uint256 base, uint256 premium);
    function MIN_COMMITMENT_AGE() external view returns (uint64);
}

interface IMockUSDC {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// Live ENSv2 UserRegistry (impl 0x9BD8a88719068D09ecee662f36C0E3856708366a, Sourcify exact match).
interface IUserRegistry {
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
}

interface IETHRegistryV2 {
    function setSubregistry(uint256 anyId, address registry) external;
    function getSubregistry(string calldata label) external view returns (address);
    function getResolver(string calldata label) external view returns (address);
}
