--- Test environment of the conformance fixture Kit: Registry, then DemoKit, on
--- the Retail client profile, which has secret values.
local FrameworkTestEnv = require("FrameworkTestEnv")

return FrameworkTestEnv.New({ modules = { "Registry", "DemoKit" }, wowProfile = "mainline" })
