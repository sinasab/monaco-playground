// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./ExampleCar.sol";

contract MyCar is ExampleCar {
    constructor(Monaco _monaco) ExampleCar(_monaco) {}
}
