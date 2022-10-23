// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "forge-std/Test.sol";

import "../src/Monaco.sol";
import "../src/cars/ExampleCar.sol";
import "../src/cars/MyCar.sol";

contract MonacoTest is Test {
    Monaco monaco;

    function setUp() public {
        monaco = new Monaco();
    }

    function testGames() public {
        ExampleCar w1 = new MyCar(monaco);
        ExampleCar w2 = new ExampleCar(monaco);
        ExampleCar w3 = new ExampleCar(monaco);

        monaco.register(w1);
        monaco.register(w2);
        monaco.register(w3);

        while (monaco.state() != Monaco.State.DONE) {
            monaco.play(1);
            emit log("");
            Monaco.CarData[] memory allCarData = monaco.getAllCarData();

            for (uint256 i = 0; i < allCarData.length; i++) {
                Monaco.CarData memory car = allCarData[i];

                emit log_address(address(car.car));
                emit log_named_uint("balance", car.balance);
                emit log_named_uint("speed", car.speed);
                emit log_named_uint("y", car.y);
            }
        }

        emit log_named_uint("Number Of Turns", monaco.turns());
    }
}
