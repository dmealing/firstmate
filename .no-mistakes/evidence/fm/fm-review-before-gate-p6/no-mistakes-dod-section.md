# no-mistakes Brief - Definition of done Section

# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch, after both passes below have run and you have resolved what they find.
Run a review pass over your branch's full change first (/code-review), so the gate spends its rounds on real defects rather than on ones an ordinary review would have caught.
Then a simplification pass over that same change (/simplify), so what ships is the smallest correct version of it rather than the first one that worked.
Run each with the named command, or by hand where your harness has no such command.
When you believe it is complete, append `done: {summary}` to the status file and stop, with the summary saying both passes ran and what they changed.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

