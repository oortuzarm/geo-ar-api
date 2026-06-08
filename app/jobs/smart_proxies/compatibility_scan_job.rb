module SmartProxies
  class CompatibilityScanJob < ApplicationJob
    queue_as :default

    def perform(smart_proxy_id)
      proxy = SmartProxy.find_by(id: smart_proxy_id)
      return unless proxy

      SmartProxies::CompatibilityScanner.new(proxy).call
    end
  end
end
