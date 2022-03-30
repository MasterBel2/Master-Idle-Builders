function widget:GetInfo()
    return {
        name = "Idle Builders (MasterBel2 Edition)",
        desc = "Makes sure you're aware of your idle (and-soon-to-be-idle) builders",
        author = "MasterBel2",
        version = 0,
        date = "March 2022",
        license = "GNU GPL, v2 or later",
        layer = 0
    }
end

------------------------------------------------------------------------------------------------------------
-- Imports
------------------------------------------------------------------------------------------------------------

local MasterFramework
local requiredFrameworkVersion = 13
local key

local Spring_GetCameraPosition = Spring.GetCameraPosition
local Spring_GetCommandQueue = Spring.GetCommandQueue
local Spring_GetFullBuildQueue = Spring.GetFullBuildQueue
local Spring_GetMyTeamID = Spring.GetMyTeamID
local Spring_GetTeamUnitsByDefs = Spring.GetTeamUnitsByDefs
local Spring_GetUnitDefID = Spring.GetUnitDefID
local Spring_GetUnitIsDead = Spring.GetUnitIsDead
local Spring_GetUnitPosition = Spring.GetUnitPosition
local Spring_PlaySoundFile = Spring.PlaySoundFile
local Spring_SetCameraTarget = Spring.SetCameraTarget

local math_floor = math.floor

local table_insert = table.insert
local table_remove = table.remove

------------------------------------------------------------------------------------------------------------
-- Stats
------------------------------------------------------------------------------------------------------------

local function normalisedDistanceFromCamera(directionalCameraLocation, directionalDistanceToUnit, normalisingFactor)
    return directionalCameraLocation - (directionalDistanceToUnit / normalisingFactor)
end

------------------------------------------------------------------------------------------------------------
-- Colors
------------------------------------------------------------------------------------------------------------

local shading

------------------------------------------------------------------------------------------------------------
-- Interface Elements
------------------------------------------------------------------------------------------------------------

local rasterizer
local idleBuilderStack

local gradient
local shiny
local font

local function CullOffScreen(rect)
    local cull = {}

    local width, height
    function cull:Layout(...)
        width, height = rect:Layout(...)
        return width, height
    end
    function cull:Draw(x, y)
        if x + width > 0 and x < MasterFramework.viewportWidth and y + height > 0 and y < MasterFramework.viewportHeight then
            rect:Draw(x, y)
        end 
    end
    return cull
end

local function PressableBuildIcon(unitDefID, action)
    local buildPicRect = MasterFramework:Rect(
        MasterFramework:Dimension(40),
        MasterFramework:Dimension(40),
        MasterFramework:Dimension(5),
        { MasterFramework:Image("#" .. unitDefID), gradient, shiny }
    )

    local countupText = MasterFramework:Text("", nil, nil, nil, font)

    return CullOffScreen(MasterFramework:StackInPlace({ 
            MasterFramework:MousePressResponder(
                buildPicRect,
                function() 
                    buildPicRect.decorations[4] = shading
                    rasterizer.invalidated = true
                    return true
                end,
                function() end,
                function()
                    rasterizer.invalidated = true
                    buildPicRect.decorations[4] = nil
                    action()
                end
            ),
            countupText
        },
        0.5,
        0.5 
    )),
    countupText
end

------------------------------------------------------------------------------------------------------------
-- Create / Destroy
------------------------------------------------------------------------------------------------------------

local builderDefIDs = {}
for unitDefID, unitDef in pairs(UnitDefs) do
    if unitDef.buildSpeed > 0 and not string.find(unitDef.name, 'spy') then
        table_insert(builderDefIDs, unitDefID)
    end
end

local max = math.max
local min = math.min
local maxDisplacement = 200

local function round(number)
	return ceil(number - 0.5)
end

local function Team(id)
    local team = {
        idleBuilderElements = {},
        idleBuilders = {},

        -- Records every instance a unit became idle or stopped being idle. 
        -- Each record is of the format { frameNumber, unitDefID, didBecomeIdle = boolean }
        -- Is an array, written in chronological order
        framesIdleStateChanged = {}
    }

    function team:UpdateIdleBuilders(gameFrame)
        local builderIDs = Spring_GetTeamUnitsByDefs(id, builderDefIDs)

        local newBuilderID
        local shouldUpdateRasterizer = false

        for _, builderID in pairs(builderIDs) do
            local buildQueue = Spring_GetFullBuildQueue(builderID)
            local builder = self.idleBuilders[builderID]

            if (buildQueue and buildQueue[1]) or Spring_GetCommandQueue(builderID, 0) ~= 0 or Spring_GetUnitIsDead(builderID) then
                if builder then
                    self.idleBuilders[builderID] = nil
                    shouldUpdateRasterizer = true

                    table_remove(self.idleBuilderElements, builder.position)
                    
                    for unitIDToUpdate, builderToUpdate in pairs(self.idleBuilders) do
                        if builderToUpdate.position > builder.position then
                            builderToUpdate.position = builderToUpdate.position - 1
                        end
                    end

                    self.framesIdleStateChanged[#self.framesIdleStateChanged + 1] = { frame = gameFrame, builderID = builderID, idle = false }
                end
            else
                if builder then
                    builder.framesIdle = builder.framesIdle + 1
                else
                    shouldUpdateRasterizer = true
                    builder = { position = #self.idleBuilderElements + 1, framesIdle = 1 }
                    self.idleBuilders[builderID] = builder

                    local builderDefID = Spring_GetUnitDefID(builderID)

                    local icon, text = PressableBuildIcon(builderDefID, function()
                        Spring.SelectUnitArray({ [0] = builderID })
                        local x, _, z = Spring_GetUnitPosition(builderID)
                        local _, y, _ = Spring_GetCameraPosition()
                        Spring_SetCameraTarget(x, y, z, 0.1)
                    end)

                    builder.text = text

                    table_insert(self.idleBuilderElements, builder.position, icon)

                    newBuilderID = builderID

                    self.framesIdleStateChanged[#self.framesIdleStateChanged + 1] = { frame = gameFrame, builderID = builderID, idle = true }
                end
            end
        end

        return newBuilderID, shouldUpdateRasterizer
    end
    
    return team
end

local teams = {}
local previousTeam

local function map(table, transform)
    local newTable = {}

    for key, value in pairs(table) do
        local newKey, newValue = transform(key, value)
        newTable[newKey] = newValue
    end

    return newTable
end

local function debugDescription(table, name, indentation)
    indentation = indentation or 0
    Spring.Echo(string.rep("| ", indentation) .. "Table: " .. tostring(name))
    for key, value in pairs(table) do
        if type(value) == "table" then
            debugDescription(value, key, indentation + 1)
        else
            Spring.Echo(string.rep("| ", indentation + 1) .. tostring(key) .. ": " .. tostring(value))
        end
    end
end

local statsCategory
local graphData = {
    minY = 0,
    maxY = 1,
    minX = 0,
    maxX = 1,
    lines = {}
}

function widget:GameFrame(n)
    local currentTeam = Spring_GetMyTeamID()
    if currentTeam ~= previousTeam then
        rasterizer.invalidated = true
        idleBuilderStack.members = teams[currentTeam].idleBuilderElements
        previousTeam = currentTeam
    end

    for teamID, team in pairs(teams) do
        local newBuilderID, shouldUpdateRasterizer = team:UpdateIdleBuilders(n)
        
        if teamID == currentTeam then
            for _, builder in pairs(team.idleBuilders) do
                if builder.text:SetString(tostring(math_floor(builder.framesIdle / 30))) then
                    shouldUpdateRasterizer = true
                end
            end

            if shouldUpdateRasterizer then
                rasterizer.invalidated = true
            end

            if newBuilderID then
                local x, y, z = Spring_GetUnitPosition(newBuilderID)
                local cx, cy, cz = Spring_GetCameraPosition()

                local xToUnit = cx - x
                local yToUnit = cy - y
                local zToUnit = cz - z

                local distanceToUnit = math.sqrt(xToUnit * xToUnit + yToUnit * yToUnit + zToUnit * zToUnit)
                local normalisingFactor = distanceToUnit / maxDisplacement

                Spring_PlaySoundFile(
                    "LuaUI/Sounds/builderready.wav", 
                    3, 
                    normalisedDistanceFromCamera(cx, xToUnit, normalisingFactor),
                    normalisedDistanceFromCamera(cy, yToUnit, normalisingFactor), 
                    normalisedDistanceFromCamera(cz, zToUnit, normalisingFactor)
                )
            end
        end
    end

    local maxBuildersIdle = 0

    local lines = map(teams, function(teamID, team)
        local buildersIdle = 0
        local vertices = {{ x = 0, y = 0 }}

        for _, update in ipairs(team.framesIdleStateChanged) do
            table_insert(vertices, { x = update.frame, y = buildersIdle })
            buildersIdle = buildersIdle + (update.idle and 1 or -1)
            maxBuildersIdle = math.max(maxBuildersIdle, buildersIdle)

            table_insert(vertices, { x = update.frame, y = buildersIdle })
        end
        table_insert(vertices, { x = n, y = buildersIdle })

        local r, g, b, a = Spring.GetTeamColor(teamID)
        return teamID + 1, {
            color = {r = r, g = g, b = b, a = a},
            vertices = vertices
        }
    end)

    graphData.maxY = maxBuildersIdle
    graphData.maxX = n
    graphData.lines = lines 
end

function widget:Initialize()
    MasterFramework = WG.MasterFramework[requiredFrameworkVersion]
    if not MasterFramework then
        Spring.Echo("[Key Tracker] Error: MasterFramework " .. requiredFrameworkVersion .. " not found! Removing self.")
        widgetHandler:RemoveWidget(self)
        return
    end

    statsCategory = WG.MasterStats:Category("Idle Builders")
    statsCategory:AddGraph("Count", widget, graphData)
    debugDescription(statsCategory, "statsCategory")

    teamIDs = Spring.GetTeamList()
    for _, teamID in ipairs(teamIDs) do
        teams[teamID] = Team(teamID)
    end

    shading = MasterFramework:Color(1, 1, 1, 0.1)
    shiny = MasterFramework:Blending(
        GL.SRC_ALPHA, GL.ONE,
        {
            MasterFramework:VerticalGradient(
                MasterFramework:Color(1, 1, 1, 0),
                MasterFramework:Color(1, 1, 1, 0.06)
            ),
            MasterFramework:Stroke(1, MasterFramework:Color(1, 1, 1, 0.1), true)
        }
    )
    gradient = MasterFramework:VerticalGradient(
        MasterFramework:Color(0, 0, 0, 0),
        MasterFramework:Color(0, 0, 0, 0.2)
    )

    font = MasterFramework:Font("FreeSansBold.otf", 20, 3, 3)

    idleBuilderStack = MasterFramework:HorizontalStack({}, MasterFramework:Dimension(8), 0.5)

    -- rasterizing and juggling whether it should be or not can creat a perf issue when there are enough constructors that the rasterizer is always recalculating
    rasterizer = MasterFramework:Rasterizer(idleBuilderStack)

    key = MasterFramework:InsertElement(
        MasterFramework:PrimaryFrame(
            MasterFramework:FrameOfReference(
                0.5, 0.25,
                rasterizer
            )
        ),
        "Idle Builders"
    )
end

function widget:Shutdown() 
    MasterFramework:RemoveElement(key)
end