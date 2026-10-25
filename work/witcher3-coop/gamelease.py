"""Register only games launched under the guarded isolated runner's lease."""
import importlib.util
import os


def register_game(process):
    try:
        source, owner = os.environ['GAMESLOT_SOURCE'], os.environ['GAMESLOT_OWNER']
        spec = importlib.util.spec_from_file_location('gameslot', source)
        slots = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(slots)
        if not slots.register_pid(owner, process.pid):
            raise RuntimeError('No live game lease; use run-isolated-test.py')
    except BaseException:
        process.kill()
        process.wait()
        raise
