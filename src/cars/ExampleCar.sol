// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./Car.sol";

contract ExampleCar is Car {
    constructor(Monaco _monaco) Car(_monaco) {}

    function takeYourTurn(Monaco.CarData[] calldata allCars, uint256 ourCarIndex) external override {
        Monaco.CarData memory ourCar = allCars[ourCarIndex];

        // If we can afford to accelerate 3 times, let's do it.
        if (ourCar.balance > monaco.getAccelerateCost(3)) {
            ourCar.balance -= uint16(monaco.buyAcceleration(3));
            monaco.accelerate(2);
        }

        // buy a shell if they're cheap af
        if (monaco.getShellCost(1) < 200) {
            monaco.buyShell(1);
        }

        // if we're in the middle and getting tailgated, decel by 3 to set up a smoking
        if (ourCarIndex == 1 && ourCar.y - allCars[0].y < 10) {
            uint256 ourDec = monaco.carActionHoldings(ourCar.car, monaco.DECELERATE());
            if (ourDec < 3) {
                ourCar.balance -= uint16(monaco.buyDeceleration(3 - ourDec));
            }
            if (ourCar.speed > allCars[0].speed && ourCar.speed > 3) {
                monaco.decelerate(3);
            }
        }

        // If we're not in the lead (index 0) + the car ahead of us is going faster + we can afford a shell, smoke em.
        if (ourCarIndex != 0 && allCars[ourCarIndex - 1].speed > ourCar.speed && ourCar.balance > monaco.getShellCost(1)) {
            uint256 ourShell = monaco.carActionHoldings(ourCar.car, monaco.SHELL());
            if (ourShell == 0) {
                monaco.buyShell(1); // buy a shell if we don't have one, so...
            }
            monaco.fireShell(); // ...we can smoke em.

            // accelerate after smoking someone
            uint256 ourAcc = monaco.carActionHoldings(ourCar.car, monaco.ACCELERATE());
            if (ourAcc > 0) {
                monaco.accelerate(ourAcc);
            }
        }
    }
}
