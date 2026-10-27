# jupyter-binding

Run JupyterLab on a Slurm compute node and tunnel it to your machine with one command.
Prints a URL + token you can paste into VS Code (**Select Kernel → Existing Jupyter
Server**) or a browser. Works with any Slurm cluster you can reach over SSH.

## Quick start

```bash
cp jupyter-binding.env.example jupyter-binding.env   # edit: at least JB_TARGET
./bind-jupyter.sh
```

Or without a config file:

```bash
./bind-jupyter.sh --target me@login.hpc.edu --gres gpu:v100:1 --conda-env myenv --time 04:00:00
```

Ctrl-C cancels the Slurm job and closes the tunnel. `./bind-jupyter.sh --help` lists all
options; `--dry-run` prints the generated Slurm script without connecting.

## How it works

1. Opens one SSH connection (you authenticate once; it reconnects automatically if it drops).
2. Pipes a generated Slurm script to `sbatch` over stdin. Nothing is installed on the cluster
   except small state files in `~/.jupyter_binding/`.
3. The job picks a free random port and a random token, starts Jupyter, and reports back.
4. The script forwards `BIND_ADDRESS:LOCAL_PORT` to the compute node and prints the URL,
   plus when your session started and when it will end (taken from Slurm's own start/end
   times for the job, shown in your local time zone).

## Configuration

Priority: flags > `JB_*` environment variables > config file > defaults. Every flag has a
matching `JB_*` variable (see `--help` and `jupyter-binding.env.example`). Extra `sbatch`
options go after `--`:

```bash
./bind-jupyter.sh -- --qos=debug --exclusive
```

The config file is sourced as shell code, so only use files you trust.

## Session end time and warnings

The URL banner shows when the session started and when it will end. While the tunnel is
open, a live "time left" line is redrawn in place (interactive terminals only). It is computed locally from the end time fetched once at startup, so it costs no
remote calls.

Optionally, `--warn-minutes N` (`JB_WARN_MINUTES`) prints a warning and rings the terminal
bell when N minutes remain (off by default, also free). The only periodic remote call is one
small `squeue` every `--check-secs` (default 30) to notice if the job died; raise it to
check less often.

## Using it from another machine on your LAN

Set `JB_BIND_ADDRESS=0.0.0.0` on the machine running the script; it then prints that
machine's LAN IP in the URL. Anyone on the LAN with the URL (token included) can run code
on your job, so only do this on networks you trust. The default is `127.0.0.1`.

## Requirements

bash ≥ 4.4 (macOS: `brew install bash`), OpenSSH client, and on the cluster: Slurm,
a `jupyter` install reachable via `--conda-env` / `--setup-cmd`. Key-based SSH login is
strongly recommended (`ssh-copy-id`), otherwise reconnects ask for your password.

## Troubleshooting

- Job fails immediately: the script prints the tail of the Slurm and Jupyter logs
  (also in `~/.jupyter_binding/<jobid>.*.log` on the cluster).
- SSH problems: `JB_SSH_EXTRA="-vv -E /tmp/jb-ssh.log" ./bind-jupyter.sh`.
- Wrong GPU name: list valid types with `sinfo -h -o '%G' | sort -u`.
