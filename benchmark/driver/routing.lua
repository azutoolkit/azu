-- Cycles through all 100 routes (and many ids) so no route is favoured by a cache: /api/v1/resource<N>/<id>
local n = 0
request = function()
  n = n + 1
  return wrk.format("GET", "/api/v1/resource" .. (n % 100) .. "/" .. (n % 997))
end
