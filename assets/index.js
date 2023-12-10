"use strict"

const STATE_INPUT = 0;
const STATE_WAITING = 1;
const STATE_OVER = 2;

let state = STATE_INPUT;

const sessionId = document.getElementById("sessionId").value;

const letters = document.getElementsByClassName("letter");

function makeAGuess() {
    let guess = "";

    for (const letter of letters) {
        guess += letter.value;
        letter.value = "";
    }

    if (state == STATE_OVER) {
        letters[0].focus();
        return;
    }

    function disable() {
        for (const letter of letters) {
            letter.disabled = true;
        }
    }

    function enable() {
        for (const letter of letters) {
            letter.disabled = false;
        }
    }

    state = STATE_WAITING;
    disable();

    fetch("/guess", {
        method: "POST",
        body: JSON.stringify({
            sessionId: sessionId,
            word: guess,
        }),
    }).then(resp => resp.json()).then(data => {
        const row = 4 - data.attemptsLeft;

        if (row < 0) {
            return;
        }

        const table = document.getElementById("wordle");
        const tds = table.getElementsByTagName("td");

        let message;

        let allCorrect = true;

        for (let col = 0; col < 5; col++) {
            const td = tds[row * 5 + col];
            td.textContent = guess[col];

            if (data.lettersCorrect[col]) {
                td.className = "correct";
            } else {
                td.className = "wrong";
                allCorrect = false;
            }
        }

        if (allCorrect) {
            message = "You won!";
            state = STATE_OVER;
        } else if (data.attemptsLeft == 0) {
            message = "You lost! No more attempts left!";
            state = STATE_OVER;
        } else {
            message = "You have " + data.attemptsLeft + " attempts left";
            state = STATE_INPUT;
            enable();
        }

        document.getElementById("status").textContent = message;
    }).catch(() => {
        state = STATE_INPUT;
        enable();
    }).finally(() => {
        letters[0].focus();
    });
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

init();
