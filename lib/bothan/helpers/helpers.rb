require 'action_view'

module Helpers

  def protected!
    return if authorized?
    headers['WWW-Authenticate'] = 'Basic realm="Restricted Area"'
    halt 401, "Not authorized\n"
  end

  def authorized?
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    @auth.provided? and @auth.basic? and @auth.credentials and @auth.credentials == [ENV['METRICS_API_USERNAME'], ENV['METRICS_API_PASSWORD']]
  end

  def title_from_slug_or_params(params)
    title = ActionView::Base.full_sanitizer.sanitize(URI.unescape params['title']) if params['title']
    title.to_s.empty? ? title_from_slug(params['metric']) : title
  end

  def title_from_slug(slug)
    return nil if slug.nil?
    words = slug.split('-')
    words.map { |word|
      word[0].upcase + word[1..-1].downcase
    }.join(' ')
  end

  def get_settings(params, data)
    metadata = metadata(params['metric'])

    @layout = params.fetch('layout', 'rich')
    @type = params.fetch('type', visualisation_type(metadata.try(:type), data))
    @boxcolour = "##{params.fetch('boxcolour', 'ddd')}"
    @textcolour = "##{params.fetch('textcolour', '222')}"
    @autorefresh = params.fetch('autorefresh', nil)
    @title = get_title(metadata, params)
    @datatype = metadata.try(:datatype)
    @description = metadata.try(:description) || {}
    @plotly_modebar = params.fetch('plotly_modebar', 'false')
    @font_size = params.fetch('font_size', '9vh')
    @metric = params.fetch('metric', '')
    @pie_colours = fix_pie_colours(params.fetch('pie_colours', ''))
    @date_format = params.fetch('date_format', 'YYYY-MM-DD HH:mm')
    @tiles = params.fetch('tiles', 'OpenStreetMap.Mapnik')
  end

  def fix_pie_colours list
    list.split(':').map { |c| "##{c}" }.to_s.gsub('"', "'")
  end

  def get_title(metadata, params)
    if params['title'].blank?
      title = metadata.try(:title)
      if title.nil? || title == {}
        { "en" => title_from_slug_or_params(params) }
      else
        title
      end
    else
      { "en" => params['title'] }
    end
  end

  def get_start_date params
    DateTime.parse(params[:to]) - params[:from].to_seconds
  end

  def get_end_date params
    DateTime.parse(params[:from]) + params[:to].to_seconds
  end

  def metrics_config
    @metrics_config ||= YAML.load File.read('config/metrics.yml')
  end

  def metric_config(metric)
    metrics_config[metric] || {}
  end

  def metric_defaults(metric)
    metric_config(metric)['defaults'] || {}
  end

  def generate_url(metric, params)
    url = datetime_path(metric, '')
    build_url(url, params.to_query)
  end

  def build_url(url, params)
    params = params.empty? ? nil : params
    [url, params].compact.join('?')
  end

  def single?(metric, datetime)
    [Hash, Array, BSON::Document].include?(metric.class) || datetime == "single"
  end

  def datetime_path(metric, datetime)
    now = Time.now.iso8601
    if single?(metric.value, datetime)
      "#{request.scheme}://#{request.host_with_port}/metrics/#{metric.name}/#{now}"
    else
      days = 30
      before = (Time.now - (60 * 60 * 24 * days)).iso8601
      "#{request.scheme}://#{request.host_with_port}/metrics/#{metric.name}/#{before}/#{now}"
    end
  end

  def date_redirect params
    if params['oldest'].present? && params['newest'].present?
      params['type'] = 'chart' if  ['pie', 'number', 'target'].include?(params['type'])
      redirect to "#{request.scheme}://#{request.host_with_port}/metrics/#{params[:metric]}/#{DateTime.parse(params['oldest']).to_s}/#{DateTime.parse(params['newest']).to_s}?#{sanitise_params params}"
    end

    if params['oldest'].present?
      redirect to "#{request.scheme}://#{request.host_with_port}/metrics/#{params[:metric]}/#{DateTime.parse(params['oldest']).to_s}?#{sanitise_params params}"
    end
  end

  def extract_query_string qs, exclude: nil
    params = qs.split('&')
    query = {}
    params.each do |param|
      pair = param.split('=')
      query[pair[0]] = pair[1] unless pair[0] == exclude
    end
    query
  end

  def get_alternatives(value)
    alt = ['chart', 'number']
    if value.class == Array
      alt = ['tasklist']
    elsif single?(value, "")
      v = ActiveSupport::HashWithIndifferentAccess.new(value)
      alt << 'target' if v['annual_target']
      alt << 'pie' if v['total']
      alt = ['map'] if v['features']
    end
    alt
  end

  def keep_params qs
    params_to_keep = [
      'layout',
      'type',
      'boxcolour',
      'textcolour',
      'barcolour',
      'autorefresh',
      'with_path',
      'font_size',
      'pie_colours',
      'date_format',
      'tiles'
    ]

    good_params = {}

    qs.each_pair do |k, v|
      good_params[k] = v if params_to_keep.include? k
    end

    good_params
  end

  def sanitise_params qs
    a = []
    keep_params(qs).each_pair do |k, v|
      a.push "#{k}=#{v}"
    end

    a.join '&'
  end

  def config
    {
      title: ENV['METRICS_API_TITLE'],
      description: ENV['METRICS_API_DESCRIPTION'],
      license: {
        name: ENV['METRICS_API_LICENSE_NAME'],
        url: ENV['METRICS_API_LICENSE_URL'],
        image: license_image(ENV['METRICS_API_LICENSE_URL'])
      },
      publisher: {
        name: ENV['METRICS_API_PUBLISHER_NAME'],
        url: ENV['METRICS_API_PUBLISHER_URL']
      },
      certificate_url: ENV['METRICS_API_CERTIFICATE_URL']
    }
  end

  def license_image(url)
    match = url.match /https?:\/\/creativecommons.org\/licenses\/([a-z\-]+)\/([0-9\.]+)/
    if match
      "https://licensebuttons.net/l/#{match[1]}/#{match[2]}/88x31.png"
    else
      nil
    end
  end

  def metadata(metric_name)
    MetricMetadata.where(name: metric_name).first
  end

  def visualisation_type(type, data)
    if type.nil?
      guess_type(data)
    else
      type
    end
  end

  def guess_type(data)
    if data.nil?
      'chart'
    elsif data[:value].class == String
      'chart'
    elsif data[:value].class == Array && !data[:value].first[:progress].nil?
      'tasklist'
    elsif [Hash, BSON::Document].include?(data[:value].class) && !data[:value][:annual_target].nil?
      'target'
    elsif [Hash, BSON::Document].include?(data[:value].class) && Hash[*data[:value].first].class == Hash
      data[:value][:type].nil? ? 'pie' : 'map'
    else
      'chart'
    end
  end

  def embed_iframe(params = {})
    "<iframe src='#{embed_url(params)}' width='100%' height='100%' frameBorder='0' scrolling='no'></iframe>"
  end

  def embed_url(params = {})
    params = request.params.merge(params.merge(
      {
        layout: "bare"
      }
    )).to_query
    request.scheme + '://' + request.host_with_port + request.path +  '?' + params
  end

  def dashboard_url(name, date, params)
    params = params.to_query
    "/metrics/#{name}/#{date || '*/*'}?#{params}"
  end

  def update_metric(name, time, value)
    @metric = Metric.new({
      "name" => name.parameterize,
      "time" => time,
      "value" => value
    })

    metadata = MetricMetadata.find_or_create_by(name: name.parameterize)

    if metadata.title.blank?
      metadata.title[:en] = name
      metadata.save
    end

    if @metric.save
      Pusher.trigger(name.parameterize, 'updated', {})
      return 201
    else
      return 500
    end
  end

  def error_406
    content_type 'text/plain'
    error 406, "Not Acceptable"
  end

  def error_400(error)
    content_type 'text/plain'
    error 400, {:status => error}.to_json
  end

  def get_single_metric(params, time)
    time ||= DateTime.now
    metrics = Metric.where(name: params[:metric].parameterize, :time.lte => time).order_by(:time.asc)
    metric = metrics.last

    if params['default-dates'].present?
      url = generate_url(metric, keep_params(params))
      redirect to url
    end

    @metric = (metric.nil? ? {} : metric).to_json

    @date = time.to_s
    @earliest_date = metrics.first.time rescue nil

    respond_to do |wants|
      wants.json { @metric }

      wants.html do
        metric = JSON.parse(@metric, {:symbolize_names => true})
        @alternatives = get_alternatives(metric[:value])

        get_settings(params, metric)
        erb :metric, layout: "layouts/#{@layout}".to_sym
      end

      wants.other { error_406 }
    end
  end

  def get_metric_range(params)
    @from = params[:from]
    @to = params[:to]

    dates = DateWrangler.new @from, @to

    error_400 dates.errors.join ' ' if dates.errors

    metrics = Metric.where(:name => params[:metric].parameterize).asc(:time)

    if params['default-dates'].present?
      url = generate_url(metrics.first, keep_params(params))
      redirect to url
    end

    @earliest_date = metrics.first.time
    @latest_date = metrics.last.time

    metrics = metrics.where(:time.gte => dates.from) if dates.from
    metrics = metrics.where(:time.lte => dates.to) if dates.to

    metrics = metrics.order_by(:time.asc)

    data = {
      :count => metrics.count,
      :values => []
    }

    metrics.each do |metric|
      data[:values] << {
        :time => metric.time,
        :value => metric.value
      }
    end

    respond_to do |wants|
      wants.json { data.to_json }

      wants.html do
        value = data[:values].first || { value: '' }
        @alternatives = get_alternatives(value[:value])

        get_settings(params, value)

        erb :metric, layout: "layouts/#{@layout}".to_sym
      end

      wants.other { error_406 }
    end
  end

end

class String
  def titleise
    self.split(' ').map { |w| "#{w[0].upcase}#{w[1..-1]}" }.join ' '
  end

  def is_duration?
    return true if self =~ /^P/
    false
  end

  def to_seconds
    ISO8601::Duration.new(self).to_seconds.seconds
  end
end
