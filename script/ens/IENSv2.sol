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
