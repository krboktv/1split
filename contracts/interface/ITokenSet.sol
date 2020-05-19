pragma solidity ^0.5.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface ITokenSet is IERC20 {

    function getUnits() external view returns (uint256[] memory);

    function naturalUnit() external view returns (uint256);

    function getComponents() external view returns (IERC20[] memory);

    function validSets(address _set) external view returns (bool);
}
