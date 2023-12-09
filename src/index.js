"use strict"

const word = "CHEEZ";
const letters = document.getElementsByClassName("letter");

let attemptsLeft = 5;
let over = false;

function outputGuess(guess) {
    const row = 5 - attemptsLeft;

    if (row < 0) {
        return;
    }

    const table = document.getElementById("wordle");

    const tds = table.getElementsByTagName("td");

    for (let col = 0; col < 5; col++) {
        const td = tds[row * 5 + col];

        td.textContent = guess[col];

        if (word[col] == guess[col]) {
            td.className = "correct";
        } else {
            td.className = "wrong";
        }
    }
}

function makeAGuess() {
    let guess = "";

    for (const letter of letters) {
        guess += letter.value;
        letter.value = "";
    }

    let message;

    if (over) {
        letters[0].focus();
        return;
    }

    outputGuess(guess);
    attemptsLeft--;

    if (word == guess) {
        message = "You won!";
        over = true;
    } else if (attemptsLeft == 0) {
        message = "You used up all your attempts!";
        over = true;
    } else {
        message = "You have " + attemptsLeft + " attempts left";
    }

    document.getElementById("status").textContent = message;
    letters[0].focus();
}

function mergeLetterInputFields() {
    function makeHandler(i, typeHandler) {
        const validLetters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

        return (ev) => {
            ev.preventDefault();

            if (ev.code == "Backspace") {
                letters[i].value = "";

                if (i != 0) {
                    letters[i - 1].focus();
                }

                return;
            }

            if (!validLetters.includes(ev.key)) {
                return;
            }

            letters[i].value = ev.key.toUpperCase();
            typeHandler();
        };
    }

    let idx;

    for (idx = 0; idx < 4; idx++) {
        const i = idx;

        letters[i].addEventListener("keydown", makeHandler(i, (ev) => {
            letters[i + 1].focus();
        }));
    }

    letters[idx].addEventListener("keydown", makeHandler(idx, (ev) => {
        makeAGuess();
    }));
}

function init() {
    mergeLetterInputFields();
    letters[0].focus();
}
