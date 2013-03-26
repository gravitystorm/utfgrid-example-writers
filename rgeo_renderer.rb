#!/usr/bin/ruby

require 'rgeo/shapefile'
require 'json'

class Extent
  attr_accessor(:minx, :miny, :maxx, :maxy)

  def initialize(minx, miny, maxx, maxy)
    @minx = minx.to_f
    @miny = miny.to_f
    @maxx = maxx.to_f
    @maxy = maxy.to_f
  end

  def width
    return @maxx - @minx
  end

  def height
    return @maxy - @miny
  end

  def to_s
    return 'Extent(%s,%s,%s,%s)' % [@minx,@miny,@maxx,@maxy]
  end
end

class Request
  attr_accessor(:width, :height, :extent)

  def initialize(width, height, extent)
    @width = width
    @height = height
    @extent = extent
  end
end

class CoordTransform
  attr_accessor(:request)

  def initialize(request, offset_x = 0.0, offset_y = 0.0)
    @request = request
    @extent = request.extent
    @offset_x = offset_x
    @offset_y = offset_y
    @sx = request.width.to_f / @extent.width
    @sy = request.height.to_f / @extent.height
  end

  def forward(x,y)
    """Lon/Lat to pixmap"""
    x0 = (x - @extent.minx) * @sx - @offset_x
    y0 = (@extent.maxy - y) * @sy - @offset_y
    return x0,y0
  end

  def backward(x,y)
    """Pixmap to Lon/Lat"""
    x0 = @extent.minx + (x + @offset_x) / @sx
    y0 = @extent.maxy - (y + @offset_y) / @sy
    return x0,y0
  end
end

def escape_codepoints(codepoint)
  """Skip the codepoints that cannot be encoded directly in JSON.
  """
  if codepoint == 34
    codepoint += 1 # skip "
  elsif codepoint == 92
    codepoint += 1 # Skip backslash
  end
  return codepoint
end

class Grid
  attr_accessor(:rows, :resolution, :feature_cache)

  def initialize(resolution = 4)
    @rows = []
    @feature_cache = {}
    @resolution = resolution
  end

  def width
    @rows.length
  end

  def height
    @rows.length
  end

  def encode
    keys = {}
    key_order = []
    data = {}
    utf_rows = []
    codepoint = 32
    (0...self.height).each do |y|
      row_utf = ''
      row = @rows[y]
      (0...self.width).each do |x|
        feature_id = row[x]
        if keys.has_key?(feature_id)
          row_utf += keys[feature_id].chr
        else
          codepoint = escape_codepoints(codepoint)
          keys[feature_id] = codepoint
          key_order << feature_id
          if @feature_cache.has_key?(feature_id)
            data[feature_id] = @feature_cache[feature_id]
          end
          row_utf += codepoint.chr
          codepoint += 1
        end
      end
      utf_rows << row_utf
    end

    utf = {}
    utf['grid'] = utf_rows
    utf['keys'] = key_order.map{|key| key.to_s}
    utf['data'] = data
    return utf
  end
end

class Renderer
  def initialize(grid, ctrans, factory)
    @grid = grid
    @ctrans = ctrans
    @req = ctrans.request
    @factory = factory
  end

  def apply(layer, field_names = [])
    fields = []
    repl = false
    attrs = layer.next.keys
    attrs.each do |attr|
      if field_names.include?(attr)
        fields << attr
      end
    end

    if fields.length == 0
      raise "No valid fields, field_names was #{field_names}"
    end

    layer.rewind

    (0...@req.height).step(@grid.resolution).each do |y|
      row = []
      (0...@req.width).step(@grid.resolution).each do |x|
        minx, maxy = @ctrans.backward(x, y)
        maxx, miny = @ctrans.backward(x + 1, y + 1)
        bbox = RGeo::Cartesian::BoundingBox.new(@factory)
        bbox.add(@factory.point(minx,maxy)).add(@factory.point(maxx, miny))
        g = bbox.to_geometry

        found = false
        layer.each do |feat|
          if feat.geometry.intersects?(g)
            repl = true
            feature_id = feat.index
            row << feature_id
            attr = {}
            attr = feat.attributes.select{|k| fields.include?(k)}
            @grid.feature_cache[feature_id] = attr
            found = true
            # Note that skipping the rest of the features
            # effectively grabs the first intersecting feature
            break
          else
            #puts "no"
          end
        end
        layer.rewind

        row << "" unless found
      end

      @grid.rows << row
    end
  end
end

proj_4326 = "+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs"
factory_4326 = RGeo::Cartesian.factory(srid: 4326, proj4: proj_4326)

shapefile = RGeo::Shapefile::Reader.open('data/ne_110m_admin_0_countries.shp', srid: 4326, factory_generator: factory_4326, assume_inner_follows_outer: true)
box = Extent.new(-140,0,-50,90)
tile = Request.new(256,256,box)
ctrans = CoordTransform.new(tile)
grid = Grid.new
renderer = Renderer.new(grid, ctrans, factory_4326)
renderer.apply(shapefile, ['NAME_FORMA', 'POP_EST'])
utfgrid = grid.encode
puts JSON.pretty_generate(utfgrid)
