local Tape = torch.class("autobw.Tape")

local utils = require'autobw.utils'
local ptr = torch.pointer

function Tape:__init()
end

-- loops over zip(tbl1, tbl2), applying f to the pairs of *tensors*
-- if tbl1 and tbl2 are tensors, then just apply f
local function zip_foreach(tbl1, tbl2, f)
    if utils.istensor(tbl1) and utils.istensor(tbl2) then
        f(tbl1, tbl2)
    elseif utils.istable(tbl1) and utils.istable(tbl2) then
        assert(#tbl1 == #tbl2)
        for i=1,#tbl1 do
            assert(utils.istensor(tbl1[i]))
            assert(utils.istensor(tbl2[i]))
            f(tbl1[i], tbl2[i])
        end
    else
        -- TODO: handle nested tables of tensors?
        error('shouldnt reach here, type mismatch between tbl1 and tbl2?')
    end
end

-- given a tensor (e.g. x), returns the adjoint for it
-- given a table of tensors, returns all their adjoints
-- note: shape of return value always the same as its input
-- note2: if any of the output tensors are not in mapping, returns a zero tensor
function Tape:_adjoint(x)
    local mapping = self._x_to_dx

    if utils.istensor(x) then
        return mapping[ptr(x)] or self:_zero(x)
    elseif utils.istable(x) then
        local ret = {}
        for i=1,#x do
            ret[i] = mapping[ptr(x[i])] or self:_zero(x[i])
        end
        return ret
    else
        -- TODO: handle nested tables of tensors?
        error('shouldnt reach here')
    end
end

-- returns an efficient zero tensor, with same size and type as t
function Tape:_zero(t)
    local tensortype = t:type()
    self._zeros = self._zeros or {}
    self._zeros[tensortype] = self._zeros[tensortype] or t.new(1):zero()

    -- TODO: is it necessary to cache these, or is tensor ctor lightweight enough?
    -- it is definitely the case that memory-wise these are cheap, though
    
    -- note that t:size() returns a new LongStorage each time
    -- t.new(storage, storageOffset, size, stride)
    local storage = self._zeros[tensortype]:storage()
    return t.new(storage, 1, t:size(), t:size():fill(0))
end

function Tape:begin()
    self.tape = {}
    self._x_to_dx = {} -- map tensor's ptr to the corresp dtensor

    self._orig_mod_forward = nn.Module.forward
    nn.Module.forward = function(self_, input)
        -- capture forward pass's input and output
        local output = self._orig_mod_forward(self_, input)
        self.tape[#self.tape+1] = { module=self_, input=input, output=output }
        return output
    end

    self._orig_crit_forward = nn.Criterion.forward
    nn.Criterion.forward = function(self_, input, target)
        local output = self._orig_crit_forward(self_, input, target)
        self.tape[#self.tape+1] = { criterion=self_, input=input, target=target, output=output }
        return output
    end
end

function Tape:stop()
    nn.Module.forward = self._orig_mod_forward
    nn.Criterion.forward = self._orig_crit_forward
end

function Tape:record(func, ...)
    self:begin()
    local result = {func(...)}
    self:stop()
    return unpack(result)
end

function Tape:backward()
    local tape = self.tape
    for i=#self.tape,1,-1 do
        local o = self.tape[i]
        local dinput
        if o.criterion then
            -- call: gradInput = criterion:backward(input, target)
            dinput = o.criterion:backward(o.input, o.target)
        elseif o.module then
            -- first, prepare "gradOutput" (doutput)
            local doutput = self:_adjoint(o.output)
            -- then call: gradInput = module:backward(input, gradOutput)
            dinput = o.module:backward(o.input, doutput)
        else
            error('internal autobw error: tape contains an non-module/criterion object')
        end

        if dinput then
            zip_foreach(o.input, dinput, function(x, dx)
                self._x_to_dx[ptr(x)] = dx
            end)
        end
    end
end

