// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "solmate/auth/Owned.sol";
import "solmate/utils/SafeCastLib.sol";
import "solmate/utils/ReentrancyGuard.sol";

import "./utils/SignedWadMath.sol";

import "./cars/Car.sol";

/// @title 0xMonaco: On-Chain Racing Game
/// @author transmissions11 <t11s@paradigm.xyz>
/// @author Bobby Abbott <bobby@paradigm.xyz>
/// @author Sina Sabet <sina@paradigm.xyz>
/// @dev Note: While 0xMonaco was originally written to be played as part
/// of the Paradigm CTF, it's not intended to have any hidden vulnerabilities.
contract Monaco is ReentrancyGuard, Owned(msg.sender) {
    using SafeCastLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event AcceleratePurchased(
        uint256 indexed turn,
        Car indexed purchaser,
        uint256 amount,
        uint256 cost
    );
    event AccelerateSold(
        uint256 indexed turn,
        Car indexed purchaser,
        uint256 amount,
        uint256 proceeds
    );
    event Accelerated(uint256 indexed turn, Car indexed car, uint256 amount);

    event DeceleratePurchased(
        uint256 indexed turn,
        Car indexed purchaser,
        uint256 amount,
        uint256 cost
    );
    event DecelerateSold(
        uint256 indexed turn,
        Car indexed purchaser,
        uint256 amount,
        uint256 proceeds
    );
    event Decelerated(uint256 indexed turn, Car indexed car, uint256 amount);

    event Dub(uint256 indexed turn, Car indexed winner);

    event Registered(uint256 indexed turn, Car indexed car);

    event Shelled(uint256 indexed turn, Car indexed smoker, Car indexed smoked);
    event ShellsSold(
        uint256 indexed turn,
        Car indexed purchaser,
        uint256 amount,
        uint256 proceeds
    );
    event ShellsPurchased(
        uint256 indexed turn,
        Car indexed purchaser,
        uint256 amount,
        uint256 cost
    );

    event TurnCompleted(
        uint256 indexed turn,
        CarData[] cars,
        uint256 acceleratePrice,
        uint256 shellPrice
    );

    /*//////////////////////////////////////////////////////////////
                         MISCELLANEOUS CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant SELL_SPREAD = 0.95e18;

    uint256 internal constant FINISH_DISTANCE = 1000;

    uint256 internal constant PLAYERS_REQUIRED = 3;

    uint16 internal constant POST_SHELL_SPEED = 1;

    uint16 internal constant STARTING_BALANCE = 15000;

    /*//////////////////////////////////////////////////////////////
                            PRICING CONSTANTS
    //////////////////////////////////////////////////////////////*/

    int256 internal constant SHELL_TARGET_PRICE = 200e18;
    int256 internal constant SHELL_PER_TURN_DECREASE = 0.33e18;
    int256 internal constant SHELL_SELL_PER_TURN = 0.2e18;

    int256 internal constant ACCELERATE_TARGET_PRICE = 10e18;
    int256 internal constant ACCELERATE_PER_TURN_DECREASE = 0.33e18;
    int256 internal constant ACCELERATE_SELL_PER_TURN = 2e18;

    // cheap af ?
    int256 internal constant DECELERATE_TARGET_PRICE = 1e18;
    int256 internal constant DECELERATE_PER_TURN_DECREASE = 0.33e18;
    int256 internal constant DECELERATE_SELL_PER_TURN = 2e18;

    /*//////////////////////////////////////////////////////////////
                               GAME STATE
    //////////////////////////////////////////////////////////////*/

    enum State {
        WAITING,
        ACTIVE,
        DONE
    }

    State public state; // The current state of the game: pre-start, started, done.

    uint16 public turns = 1; // Number of turns played since the game started.

    uint72 public entropy; // Random data used to shuffle the list of cars.

    Car public currentCar; // The car that is currently taking its turn.

    /*//////////////////////////////////////////////////////////////
                               SALES STATE
    //////////////////////////////////////////////////////////////*/

    enum ActionType {
        ACCELERATE,
        DECELERATE,
        SHELL
    }
    ActionType public ACCELERATE = ActionType.ACCELERATE;
    ActionType public DECELERATE = ActionType.DECELERATE;
    ActionType public SHELL = ActionType.SHELL;

    mapping(ActionType => uint256) public getNetActionsSold;

    /*//////////////////////////////////////////////////////////////
                               CAR STORAGE
    //////////////////////////////////////////////////////////////*/

    struct CarData {
        uint192 balance; // Where 0 means the car has no money.
        uint32 speed; // Where 0 means the car isn't moving.
        uint32 y; // Where 0 means the car hasn't moved.
        Car car;
    }

    Car[] public cars;

    mapping(Car => mapping(ActionType => uint256)) public carActionHoldings;
    mapping(Car => CarData) public getCarData;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function register(Car car) external onlyOwner {
        // Prevent accidentally or intentionally registering a car multiple times.
        require(address(getCarData[car].car) == address(0), "DOUBLE_REGISTER");

        // Register the caller as a car in the race.
        getCarData[car] = CarData({
            balance: STARTING_BALANCE,
            car: car,
            speed: 0,
            y: 0
        });

        cars.push(car); // Append to the list of cars.

        // Retrieve and cache the total number of cars.
        uint256 totalCars = cars.length;

        // If the game is now full, kick things off.
        if (totalCars == PLAYERS_REQUIRED) {
            // Use the timestamp as random input.
            entropy = uint72(block.timestamp);

            // Mark the game as active.
            state = State.ACTIVE;
        } else {
            require(totalCars < PLAYERS_REQUIRED, "MAX_PLAYERS");
        }

        emit Registered(0, car);
    }

    /*//////////////////////////////////////////////////////////////
                                CORE GAME
    //////////////////////////////////////////////////////////////*/

    function play(uint256 turnsToPlay)
        external
        onlyDuringActiveGame
        nonReentrant
    {
        unchecked {
            // We'll play turnsToPlay turns, or until the game is done.
            for (; turnsToPlay != 0; turnsToPlay--) {
                Car[] memory allCars = cars; // Get and cache the cars.

                uint256 currentTurn = turns; // Get and cache the current turn.

                // Get the current car by moduloing the turns variable by the player count.
                Car currentTurnCar = allCars[currentTurn % PLAYERS_REQUIRED];

                // Get all car data and the current turn car's index so we can pass it via takeYourTurn.
                (
                    CarData[] memory allCarData,
                    uint256 yourCarIndex
                ) = getAllCarDataAndFindCar(currentTurnCar);

                currentCar = currentTurnCar; // Set the current car temporarily.

                // We use assembly here to prevent players from DoS-ing the game via the extcodesize check
                // the compiler bakes in (which is not catchable via try catch) or via returndata bombing.
                bytes memory inputData = abi.encodeWithSelector(
                    Car.takeYourTurn.selector,
                    allCarData,
                    yourCarIndex
                );
                assembly {
                    // Call the currentTurnCar with 2,000,000 gas and avoid copying any returndata.
                    pop(
                        call(
                            2000000,
                            currentTurnCar,
                            0,
                            add(inputData, 32),
                            mload(inputData),
                            0,
                            0
                        )
                    )
                }

                delete currentCar; // Restore the current car to the zero address.

                // Loop over all of the cars and update their data.
                for (uint256 i = 0; i < PLAYERS_REQUIRED; i++) {
                    Car car = allCars[i]; // Get the car.

                    // Get a pointer to the car's data struct.
                    CarData storage carData = getCarData[car];

                    // If the car is now past the finish line after moving:
                    if ((carData.y += carData.speed) >= FINISH_DISTANCE) {
                        emit Dub(currentTurn, car); // It won.

                        state = State.DONE;

                        return; // Exit early.
                    }
                }

                // If this is the last turn in the batch:
                if (currentTurn % PLAYERS_REQUIRED == 0) {
                    // Knuth shuffle over the cars using our entropy as randomness.
                    for (uint256 j = 0; j < PLAYERS_REQUIRED; ++j) {
                        // Generate a new random number by hashing the old one.
                        uint256 newEntropy = (entropy = uint72(
                            uint256(keccak256(abi.encode(entropy)))
                        ));

                        // Choose a random position in front of j to swap with.
                        uint256 j2 = j + (newEntropy % (PLAYERS_REQUIRED - j));

                        Car temp = allCars[j];
                        allCars[j] = allCars[j2];
                        allCars[j2] = temp;
                    }

                    cars = allCars; // Reorder cars using the new shuffled ones.
                }

                // Note: If this line was deployed on-chain it would be a big waste of gas.
                emit TurnCompleted(
                    turns = uint16(currentTurn + 1),
                    getAllCarData(),
                    0,
                    0
                );
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 ACTIONS
    //////////////////////////////////////////////////////////////*/

    function _sellAction(ActionType actionType, uint256 amount)
        internal
        onlyDuringActiveGame
        onlyCurrentCar
        returns (uint256)
    {
        require(amount != 0, "You cant sell zero of an action");

        // Get a storage pointer to the calling car's data struct.
        CarData storage car = getCarData[Car(msg.sender)];

        uint256 proceeds = 0;
        if (actionType == ActionType.ACCELERATE) {
            proceeds = getAccelerateCost(amount);
            carActionHoldings[car.car][ActionType.ACCELERATE] -= amount;
        } else if (actionType == ActionType.DECELERATE) {
            proceeds = getDecelerateCost(amount);
            carActionHoldings[car.car][ActionType.DECELERATE] -= amount;
        } else if (actionType == ActionType.SHELL) {
            proceeds = getShellCost(amount);
            carActionHoldings[car.car][ActionType.SHELL] -= amount;
        }

        int256 tmp = wadMul(toWadUnsafe(proceeds), toWadUnsafe(SELL_SPREAD));
        if (tmp < 0) {
            revert();
        }
        unchecked {
            proceeds = uint256(tmp);
        }
        car.balance += proceeds.safeCastTo16();

        unchecked {
            getNetActionsSold[actionType] -= amount;
        }

        return proceeds;
    }

    function sellShell(uint256 amount)
        external
        onlyDuringActiveGame
        onlyCurrentCar
        returns (uint256 proceeds)
    {
        proceeds = _sellAction(ActionType.SHELL, amount);
        emit ShellsSold(turns, Car(msg.sender), amount, proceeds);
        return proceeds;
    }

    function sellDeceleration(uint256 amount)
        external
        onlyDuringActiveGame
        onlyCurrentCar
        returns (uint256 proceeds)
    {
        proceeds = _sellAction(ActionType.DECELERATE, amount);
        emit DecelerateSold(turns, Car(msg.sender), amount, proceeds);
        return proceeds;
    }

    function sellAcceleration(uint256 amount)
        external
        onlyDuringActiveGame
        onlyCurrentCar
        returns (uint256 proceeds)
    {
        proceeds = _sellAction(ActionType.ACCELERATE, amount);
        emit AccelerateSold(turns, Car(msg.sender), amount, proceeds);
        return proceeds;
    }

    function _buyAction(ActionType actionType, uint256 amount)
        internal
        onlyDuringActiveGame
        onlyCurrentCar
        returns (uint256)
    {
        require(amount != 0, "You cant buy zero of an action");

        // Get a storage pointer to the calling car's data struct.
        CarData storage car = getCarData[Car(msg.sender)];

        uint256 cost = 0;
        if (actionType == ActionType.ACCELERATE) {
            cost = getAccelerateCost(amount);
            carActionHoldings[car.car][ActionType.ACCELERATE] += amount;
        } else if (actionType == ActionType.DECELERATE) {
            cost = getDecelerateCost(amount);
            carActionHoldings[car.car][ActionType.DECELERATE] += amount;
        } else if (actionType == ActionType.SHELL) {
            cost = getShellCost(amount);
            carActionHoldings[car.car][ActionType.SHELL] += amount;
        }

        car.balance -= cost.safeCastTo16();

        unchecked {
            getNetActionsSold[actionType] += amount;
        }

        return cost;
    }

    function buyShell(uint256 amount)
        external
        onlyDuringActiveGame
        onlyCurrentCar
        returns (uint256 cost)
    {
        cost = _buyAction(ActionType.SHELL, amount);
        emit ShellsPurchased(turns, Car(msg.sender), amount, cost);
    }

    function buyDeceleration(uint256 amount)
        external
        onlyDuringActiveGame
        onlyCurrentCar
        returns (uint256 cost)
    {
        cost = _buyAction(ActionType.DECELERATE, amount);
        emit DeceleratePurchased(turns, Car(msg.sender), amount, cost);
    }

    function buyAcceleration(uint256 amount)
        external
        onlyDuringActiveGame
        onlyCurrentCar
        returns (uint256 cost)
    {
        cost = _buyAction(ActionType.ACCELERATE, amount);
        emit AcceleratePurchased(turns, Car(msg.sender), amount, cost);
    }

    function decelerate(uint256 amount)
        external
        onlyDuringActiveGame
        onlyCurrentCar
    {
        CarData storage car = getCarData[Car(msg.sender)];
        carActionHoldings[car.car][ActionType.DECELERATE] -= amount;
        car.speed -= uint16(amount);

        emit Decelerated(turns, Car(msg.sender), amount);
    }

    function accelerate(uint256 amount)
        external
        onlyDuringActiveGame
        onlyCurrentCar
    {
        CarData storage car = getCarData[Car(msg.sender)];
        carActionHoldings[car.car][ActionType.ACCELERATE] -= amount;
        car.speed += uint16(amount);

        emit Accelerated(turns, Car(msg.sender), amount);
    }

    function fireShell() external onlyDuringActiveGame onlyCurrentCar {
        CarData storage car = getCarData[Car(msg.sender)];
        // Shell is fired regardless of whether there is a car in front
        carActionHoldings[car.car][ActionType.SHELL] -= 1;

        uint256 y = car.y; // Retrieve and cache the car's y.

        unchecked {
            Car closestCar; // Used to determine who to shell.
            uint256 distanceFromClosestCar = type(uint256).max;

            for (uint256 i = 0; i < PLAYERS_REQUIRED; i++) {
                CarData memory nextCar = getCarData[cars[i]];

                // If the car is behind or on us, skip it.
                if (nextCar.y <= y) {
                    continue;
                }

                // Measure the distance from the car to us.
                uint256 distanceFromNextCar = nextCar.y - y;

                // If this car is closer than all other cars we've
                // looked at so far, we'll make it the closest one.
                if (distanceFromNextCar < distanceFromClosestCar) {
                    closestCar = nextCar.car;
                    distanceFromClosestCar = distanceFromNextCar;
                }
            }

            // If there is a closest car, shell it.
            if (address(closestCar) != address(0)) {
                // Set the speed to POST_SHELL_SPEED unless its already at that speed or below, as to not speed it up.
                if (getCarData[closestCar].speed > POST_SHELL_SPEED) {
                    getCarData[closestCar].speed = POST_SHELL_SPEED;
                }
            }

            emit Shelled(turns, Car(msg.sender), closestCar);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             ACTION PRICING
    //////////////////////////////////////////////////////////////*/

    function getDecelerateCost(uint256 amount)
        public
        view
        returns (uint256 sum)
    {
        unchecked {
            for (uint256 i = 0; i < amount; i++) {
                sum += computeActionPrice(
                    DECELERATE_TARGET_PRICE,
                    DECELERATE_PER_TURN_DECREASE,
                    turns,
                    getNetActionsSold[ActionType.DECELERATE] + i,
                    DECELERATE_SELL_PER_TURN
                );
            }
        }
    }

    function getAccelerateCost(uint256 amount)
        public
        view
        returns (uint256 sum)
    {
        unchecked {
            for (uint256 i = 0; i < amount; i++) {
                sum += computeActionPrice(
                    ACCELERATE_TARGET_PRICE,
                    ACCELERATE_PER_TURN_DECREASE,
                    turns,
                    getNetActionsSold[ActionType.ACCELERATE] + i,
                    ACCELERATE_SELL_PER_TURN
                );
            }
        }
    }

    function getShellCost(uint256 amount) public view returns (uint256 sum) {
        unchecked {
            for (uint256 i = 0; i < amount; i++) {
                sum += computeActionPrice(
                    SHELL_TARGET_PRICE,
                    SHELL_PER_TURN_DECREASE,
                    turns,
                    getNetActionsSold[ActionType.SHELL] + i,
                    SHELL_SELL_PER_TURN
                );
            }
        }
    }

    function computeActionPrice(
        int256 targetPrice,
        int256 perTurnPriceDecrease,
        uint256 turnsSinceStart,
        uint256 sold,
        int256 sellPerTurnWad
    ) internal pure returns (uint256) {
        unchecked {
            // prettier-ignore
            return uint256(
                wadMul(
                    targetPrice,
                    wadExp(
                        unsafeWadMul(
                            wadLn(1e18 - perTurnPriceDecrease),
                            // Theoretically calling toWadUnsafe with turnsSinceStart and sold can overflow without
                            // detection, but under any reasonable circumstance they will never be large enough.
                            // Use sold + 1 as we need the number of the tokens that will be sold (inclusive).
                            // Use turnsSinceStart - 1 since turns start at 1 but here the first turn should be 0.
                            toWadUnsafe(turnsSinceStart - 1) - (wadDiv(toWadUnsafe(sold + 1), sellPerTurnWad))
                        )
                    )
                )
            ) / 1e18;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyDuringActiveGame() {
        require(state == State.ACTIVE, "GAME_NOT_ACTIVE");

        _;
    }

    modifier onlyCurrentCar() {
        require(Car(msg.sender) == currentCar, "NOT_CURRENT_CAR");

        _;
    }

    function getAllCarData() public view returns (CarData[] memory results) {
        results = new CarData[](PLAYERS_REQUIRED); // Allocate the array.

        // Get a list of cars sorted descendingly by y.
        Car[] memory sortedCars = getCarsSortedByY();

        unchecked {
            // Copy over each car's data into the results array.
            for (uint256 i = 0; i < PLAYERS_REQUIRED; i++) {
                results[i] = getCarData[sortedCars[i]];
            }
        }
    }

    function getAllCarDataAndFindCar(Car carToFind)
        public
        view
        returns (CarData[] memory results, uint256 foundCarIndex)
    {
        results = new CarData[](PLAYERS_REQUIRED); // Allocate the array.

        // Get a list of cars sorted descendingly by y.
        Car[] memory sortedCars = getCarsSortedByY();

        unchecked {
            // Copy over each car's data into the results array.
            for (uint256 i = 0; i < PLAYERS_REQUIRED; i++) {
                Car car = sortedCars[i];

                // Once we find the car, we can set the index.
                if (car == carToFind) {
                    foundCarIndex = i;
                }

                results[i] = getCarData[car];
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              SORTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function getCarsSortedByY()
        internal
        view
        returns (Car[] memory sortedCars)
    {
        unchecked {
            sortedCars = cars; // Initialize sortedCars.

            // Implements a descending bubble sort algorithm.
            for (uint256 i = 0; i < PLAYERS_REQUIRED; i++) {
                for (uint256 j = i + 1; j < PLAYERS_REQUIRED; j++) {
                    // Sort cars descendingly by their y position.
                    if (
                        getCarData[sortedCars[j]].y >
                        getCarData[sortedCars[i]].y
                    ) {
                        Car temp = sortedCars[i];
                        sortedCars[i] = sortedCars[j];
                        sortedCars[j] = temp;
                    }
                }
            }
        }
    }
}