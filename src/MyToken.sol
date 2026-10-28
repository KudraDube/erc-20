// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MyToken {

error ZeroAddress();
error InsufficientBalance();
error InsufficientAllowance();

event Transfer(address indexed from, address indexed to, uint256 value);
event Approval(address indexed owner, address indexed spender, uint256 value);

string public name;
string public symbol;
uint8 public constant decimals = 18;
uint256 public totalSupply;
mapping(address => uint256) public balanceOf;

mapping(address => mapping(address => uint256)) public allowance;
constructor(string memory _name, string memory _symbol, uint256 initialSupply) {
name = _name;
symbol = _symbol;
_mint(msg.sender, initialSupply);
}

function transfer(address to, uint256 amount) external returns (bool) {
_transfer(msg.sender, to, amount);
return true;
}

function approve(address spender, uint256 amount) external returns (bool) {
allowance[msg.sender][spender] = amount; // SET, not add. msg.sender is the owner.
emit Approval(msg.sender, spender, amount);
return true;
}

function transferFrom(address from, address to, uint256 amount) external returns (bool) {
uint256 current = allowance[from][msg.sender];

if (current != type(uint256).max) {
if (current < amount) revert InsufficientAllowance();
allowance[from][msg.sender] = current - amount;
}
_transfer(from, to, amount);

return true;
}

function _transfer(address from, address to, uint256 amount) internal {
if (to == address(0)) revert ZeroAddress();
if (balanceOf[from] < amount) revert InsufficientBalance();
balanceOf[from] -= amount;
balanceOf[to] += amount;
emit Transfer(from, to, amount);
}

function _mint(address to, uint256 amount) internal {
if (to == address(0)) revert ZeroAddress();
totalSupply += amount;
balanceOf[to] += amount;
emit Transfer(address(0), to, amount);
}

function _burn(address from, uint256 amount) internal {

if (balanceOf[from] < amount) revert InsufficientBalance();
balanceOf[from] -= amount;
totalSupply -= amount;
emit Transfer(from, address(0), amount);

}
}