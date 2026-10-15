--!strict
-- Reports the globals the loader injected, so tests can check them.
return { game = game, hasTask = task ~= nil and type(task.spawn) == "function" }
