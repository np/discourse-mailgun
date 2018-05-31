# name: discourse-mailgun
# about: Discourse Plugin for processing Mailgun webhooks
# version: 0.1
# authors: Tiago Macedo
# url: https://github.com/reallyreally/discourse-mailgun

require 'openssl'

enabled_site_setting :mailgun_api_key
enabled_site_setting :discourse_base_url
enabled_site_setting :discourse_api_key
enabled_site_setting :discourse_api_username

after_initialize do
  module ::DiscourseMailgun
    class Engine < ::Rails::Engine
      engine_name "discourse-mailgun"
      isolate_namespace DiscourseMailgun

      class << self
        # signature verification filter
        def verify_signature(timestamp, token, signature, api_key)
          digest = OpenSSL::Digest::SHA256.new
          data = [timestamp, token].join
          hex = OpenSSL::HMAC.hexdigest(digest, api_key, data)

          signature == hex
        end

        # posting the email through the discourse api
        def post(url, params)
          Excon.post(url,
            :body => URI.encode_www_form(params),
            :headers => { "Content-Type" => "application/x-www-form-urlencoded" })
        end
      end
    end
  end

  require_dependency "application_controller"

  class DiscourseMailgun::MailgunController < ::ApplicationController
    skip_before_action :redirect_to_login_if_required
   #requires_login except: [:incoming]
    before_action :verify_signature

    def incoming
      mg_body    = params['body-plain']
      mg_subj    = params['subject']
      mg_to      = params['To']
      mg_from    = params['From']
      mg_date    = params['Date']
      mg_atts    = params['attachment-count'] || 0

      m = Mail::Message.new do
        to      mg_to
        from    mg_from
        date    mg_date
        subject mg_subj
        body    mg_body

        for i in 1 .. mg_atts.to_i do
          att = params["attachment-#{i}"]
          add_file filename: att.original_filename, content: att.read
        end
      end

      handler_url = SiteSetting.discourse_base_url + "/admin/email/handle_mail"

      params = {'email'        => m.to_s,
                'api_key'      => SiteSetting.discourse_api_key,
                'api_username' => SiteSetting.discourse_api_username}
      ::DiscourseMailgun::Engine.post(handler_url, params)

      render plain: "done"
    end

    # we mark this controller as an API
    # in order to skip CSRF and other discourse filters
    def is_api?
      true
    end

    private

    def verify_signature
      timestamp = params['timestamp']
      token = params['token']
      signature = params['signature']
      valid_signature = ::DiscourseMailgun::Engine.verify_signature(timestamp, token, signature, SiteSetting.mailgun_api_key)
      unless (Time.at(timestamp.to_i) - Time.now).abs < 24.hours.to_i and valid_signature
        render json: {}, :status => :unauthorized
      end
    end
  end


  DiscourseMailgun::Engine.routes.draw do
    post "/incoming" => "mailgun#incoming"
  end

  Discourse::Application.routes.append do
    mount ::DiscourseMailgun::Engine, at: "mailgun"
  end
end
