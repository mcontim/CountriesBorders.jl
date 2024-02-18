valid_column_names() = setdiff(Tables.columnnames(getfield(GEOTABLE[], :table)), [:geometry, :featurecla, :scalerank])

possible_selector_values() = let
	f(s) = replace(s, "\0" => "")
	fields = (:ADMIN, :CONTINENT, :REGION_UN, :SUBREGION, :REGION_WB)
	NamedTuple((k => unique(map(f,getproperty(GEOTABLE[], k))) for k in fields))
end

# Make a case-insensitive regexp from a string
function _to_regexp(s::AbstractString)
    s = strip(s)
    minus_flag, pattern = if startswith(s, "-")
        true, s[2:end]
    else
        pattern = startswith(s, "+") ? s[2:end] : s
        false, pattern
    end
    pattern = replace(pattern, "*" => "[\\w\\s]*")
    pattern = "^$pattern\$"
    return minus_flag, Regex(pattern, 0x040a000a, 0x40000000)
end
# Transforms string or regexps in a vector of regexps
function _process_input(s::String)
    # Try to see if there are multiple inputs (separated by ;)
    inputs = filter(!isempty,split(s,";"))
    map(_to_regexp, inputs)
end
_process_input(v::Array) = vcat(map(_process_input, v)...)

# This function removes from the domain the areas specified in the SkipDict
function process_domain!(dmn, sd::SkipDict, geotable)
	removed_idx = falses(length(dmn))
	isempty(removed_idx) && return dmn
	for (admin, s) in sd
		idx = findfirst(startswith(admin), geotable.ADMIN)
		isnothing(idx) && continue
		geom = dmn[idx]
		if skipall(s) || length(geom.items) == length(s.idxs)
			removed_idx[idx] = true
		else
			name = admin
			lg = length(geom.items)
			mi = maximum(s.idxs)
			@assert mi <= lg "The provided idxs to remove from '$name' have at laset one idx ($mi) which is greater than the number of PolyAreas associated to '$name' ($lg PolyAreas)"
			deleteat!(geom.items, s.idxs)
		end
	end
	all(removed_idx) && @warn "Some countries were downselected but have been removed based on the contents of the `skip_area` keyword argument."
	deleteat!(dmn.items, removed_idx)
	return dmn
end

## extract_countries ##
"""
	extract_countries([shapetable::Shapefile.Table]; skip_areas = nothing, kwargs...)
	extract_countries(admin::Union{AbstractString, Vector{<:AbstractString}}; skip_areas = nothing, kwargs...)

Extract and returns the domain (`<:Meshes.Domain`) containing all the countries
that match a search query provided via the kwargs...

The returned `domain` can be used to check inclusion of `Meshes.Point` objects
or can be directly plotted using `scattergeo` from PlotlyBase and the dependent
packages (e.g. PlutoPlotly, PlotlyJS)

The function can take as input a custom `shapetable` but it's usually simply
called without one, in which case it uses the one loaded by default by the
package, which is obtained from the 1/110m maps from
[naturalearthdata.com](https://www.naturalearthdata.com/).  Specifically, the
shape file used to obtain the coordinates of the countries borders is located at
[https://github.com/nvkelso/natural-earth-vector/blob/master/110m_cultural/ne_110m_admin_0_countries_lakes.shp](https://github.com/nvkelso/natural-earth-vector/blob/master/110m_cultural/ne_110m_admin_0_countries_lakes.shp).

The `shapetable` contains a row per country and various country-related
informations among the columns

The downselection of countries to form a domain is performed by passing keyword
arguments containing `String` or `Vector{String}` values. 

# Extended Help

## Input Parsing

For each keyword argument, the function performs a downselection on the `shapetable` column whose name matches the keyword argument name. The downselection is done based on the string provided as value:
- The string is used to match the full name (case-insensitive) with the value of the specified column for each row of the table. 
- The `*` wildcard can be used within the string to expand to any number of word or space characters.
- If the string starts with the '-' character, all rows that match are removed from the current downselection. Otherwise, the matching rows are added to the downselection (One can also put a '+' in front of the string to use for the matching to emphasise addition rather than deletion).
- Multiple query/match strings can also be provided for each keyword argument, either as a vector of strings or within the same string but separated by ';'
  - The multiple queries are processed in the order they are provided, adding or removing to the total downselection accordingly
- Each keyword argument is processed in the order it was provided, also modifying the downselection as described in the previous points.
- The name of the keyword argument is made all uppercase before matching with the column names of `shapefile`, as the column names for the default table are all uppercase, so calling `extract_countries(;ConTinEnt = "Asia")` will match against the `:CONTINENT` column of the `shapefile`.

### Parsing Examples

- `extract_countries(;continent = "europe", admin="-russia")` will extract the borders of all countries within the european continent except Russia
- `extract_countries(;admin="-russia", continent = "europe")` will extract the borders of all countries within the european continent **including** Russia. This is because the strings are processed in order, so Russia is first removed and then Europe (which includes Russia) is added.
- `extract_countries(;subregion = "*europe; -eastern europe")` will extract all countries that have a `subregion` name ending with `europe` (That is northern, eastern, western and southern) but will not include countries within the `eastern europe` subregion.

For a list of possible column names, call the function
`CountriesBorders.valid_column_names()`.

For a list of the possible values contained in the table for some of the most
useful colulmn names, call the function
`CountriesBorders.possible_selector_values()`.

## Skipping Areas

Apart from removing areas with the string parsing synthax detailed above, one can also provide a list of countries (basd on the `ADMIN` name) or subareas of countries by using the `skip_area` keyword argument.

The provided `skip_area` must be an array of elements that can be:
- instances of `SkipDict`
- instances of `SkipFromAdmin`
- instances of objects that can be used directly to construct `SkipFromAdmin` objects:
  - A single `String`. (will translate to a `SkipFromAdmin` with the provided `String` as `admin` and the Colon (:) as second argument)
  - instances `t` of `Tuple{<:AbstractString, <:Any}`, in which case the resulting `SkipFromAdmin` will be created as `SkipFromAdmin(t...)`

The provided elements will be merged into a single list of countries/areas to skip which will be removed from the nominal output of `extract_countries`.

A default set of Non-continental EU areas to skip is available in the exported constant `SKIP_NONCONTINENTAL_EU` which can be passed as the `skip_areas` argument (or as one of the elements of the array passed to `skip_areas`).

### Example
```julia 
# The following code will extract the borders of Italy, France and Norway without French Guyana (part of France), without Sicily, and without the Svalbard Islands (part of Norway)
dmn = extract_countries("italy; spain; france; norway"; skip_areas = [
	("Italy", 2) # This removes the second polygon in the Italy MultiPolyArea, which corresponds to Sicily
	"Spain" # This will remove Spain in its entirety
	SKIP_NONCONTINENTAL_EU # This will remove Svalbard and French Guyana
])
```
"""
function extract_countries(shapetable::GeoTables.SHP.Table; skip_areas = nothing, kwargs...)
	downselection = falses(Tables.rowcount(shapetable))
	for (k, v) in kwargs
		key = Symbol(uppercase(string(k)))
		r_vec = try
			_process_input(v)
		catch
			error("The kwarg values have to be provided as String or Vector{String}")
		end
		for (remove_from_list, regex) in r_vec
			col_vals = map(getproperty(shapetable, key)) do str
				match(regex, replace(str, "\0" => "")) !== nothing
			end
			downselection[col_vals] .= remove_from_list ? false : true
		end
	end
	if any(downselection)
		subset = Tables.subset(shapetable, downselection; viewhint = false)
        geotable = GeoTables.GeoTable(subset)
        # We extract the domain directly to modify it in case skip_areas are provided
        dmn = domain(geotable)
		if skip_areas !== nothing
			sd = mergeSkipDict(skip_areas)
			process_domain!(dmn, sd, geotable)
		end
		return dmn
	else
		return nothing
	end
end
# Other convenience methods
extract_countries(geotable::GeoTables.GeoTable = GEOTABLE[];kwargs...) = extract_countries(getfield(geotable, :table); kwargs...)
# Method that just searches the admin column
extract_countries(name::Union{AbstractString, Vector{<:AbstractString}};kwargs...) = extract_countries(;admin = name, kwargs...)

# Extracting lat/lon coordaintes of the borders
function extract_plot_coords(pa::PolyArea)
	v = map(coordinates, pa.outer.vertices)
    lon = first.(v)
    lat = last.(v)
	return (;lon, lat)
end

function extract_plot_coords(md::Union{Multi, Domain})
	lon = Float64[]
	lat = Float64[]
	for i ∈ md.items
		tx, ty = extract_plot_coords(i)
		append!(lon, tx, [NaN])
		append!(lat, ty, [NaN])
	end
	(;lon,lat)
end
