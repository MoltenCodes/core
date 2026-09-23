local TestEnv = require("MediaKitTestEnv")

describe("MediaKit and secret values", function()
    local MediaKit
    before_each(function()
        MediaKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("refuses a secret name at the caller", function()
        local secret = "Secret Name"
        TestEnv.InstallSecretProbe(secret)
        TestEnv.expectErrorContaining(
            "MediaKit:Register name must not be a secret value",
            function()
                MediaKit:Register("statusbar", secret, "Interface\\Pack\\Bar")
            end
        )
        TestEnv.expectErrorContaining("MediaKit:Fetch name must not be a secret value", function()
            MediaKit:Fetch("statusbar", secret)
        end)
        TestEnv.expectErrorContaining("MediaKit:Has name must not be a secret value", function()
            MediaKit:Has("statusbar", secret)
        end)
    end)

    it("refuses secret data, path or FileDataID, at the caller", function()
        TestEnv.InstallSecretProbe("Interface\\Secret")
        TestEnv.expectErrorContaining(
            "MediaKit:Register data must not be a secret value",
            function()
                MediaKit:Register("statusbar", "Name", "Interface\\Secret")
            end
        )
        TestEnv.InstallSecretProbe(12345)
        TestEnv.expectErrorContaining(
            "MediaKit:Register data must not be a secret value",
            function()
                MediaKit:Register("sound", "Name", 12345)
            end
        )
        assert.is_false(MediaKit:IsFileDataID(12345))
    end)

    it("refuses a secret type", function()
        TestEnv.InstallSecretProbe("statusbar")
        TestEnv.expectErrorContaining("MediaKit:List type must not be a secret value", function()
            MediaKit:List("statusbar")
        end)
    end)

    it("skips secret LibSharedMedia entries when adopting", function()
        local library = TestEnv.InstallLibSharedMedia({
            media = { statusbar = { Hidden = "Interface\\Secret", Plain = "Interface\\Plain" } },
        })
        TestEnv.InstallSecretProbe("Interface\\Secret")
        local _, added = MediaKit:AdoptLibSharedMedia()
        assert.are.equal(1, added)
        assert.is_false(MediaKit:Has("statusbar", "Hidden"))

        TestEnv.InstallSecretProbe("Secret Key")
        library:Register("statusbar", "Secret Key", "Interface\\Anything")
        TestEnv.InstallSecretProbe({})
        assert.is_false(MediaKit:Has("statusbar", "Secret Key"))
    end)

    it("looks the probe up at call time", function()
        assert.is_true(MediaKit:Register("statusbar", "Late", "Interface\\Late"))
        TestEnv.InstallSecretProbe("Late")
        TestEnv.expectErrorContaining("must not be a secret value", function()
            MediaKit:Fetch("statusbar", "Late")
        end)
    end)
end)
