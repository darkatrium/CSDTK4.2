include CoolRuby

if(!$EVENTSNIFFERCONNECTION)
    $EVENTSNIFFERCONNECTION = registerNewToolConnection(ToolConnection.new("Event Sniffer"))
end

module EventSniffer

    class EventSnifferAlreadyRunningException < Exception
    end

    @@callbacks = Hash.new()

protected

    def sniffEventLoop()

    	if($SNIFFEVENTTHREAD != nil && $SNIFFEVENTTHREAD.alive?) then
    		raise EventSnifferAlreadyRunningException,"Event sniffer already running."
    	end

    	$SNIFFEVENTTHREAD = Thread.new() {

    	    hasgoterror = false
    	    initdone = false
    	    lastexception = nil

    		while(true) do
    			begin
    			    if (!initdone || hasgoterror)
        				$EVENTSNIFFERCONNECTION.connection.enableEvents(true)
        				$EVENTSNIFFERCONNECTION.connection.flushEvents()
  			    	    hasgoterror = false
  			    	    if (initdone)
  			    	        puts "EVENT SNIFFING RESURRECTED."
  			    	    else
  			    	        initdone = true
  			    	    end
    			    else
        			    event = $EVENTSNIFFERCONNECTION.connection.popEvent(0) #no timeout

                        if(@@callbacks[event])
                            @@callbacks[event].call
                        else
                            puts "Detected event: 0x%08x." % event
                        end
                    end

                    lastexception = nil

    			rescue NoEventError => e
    			    lastexception = e
    			    sleep(0.02) # Slow down the event sniffer when no event are received
      		    rescue UnvalidHandleError, NotConnectedError, EventsNotEnabledError, Exception => e
      		        if (lastexception.class() != e.class())
    				    #Uncomment for debugging purpose
    				    #CRExceptionPrint(e)
    				end
  		            lastexception = e

      		        if (e.instance_of?(UnvalidHandleError))
      		            #initdone = false
      		        end
				    if (initdone && !hasgoterror)
				        puts "EVENT SNIFFING ERROR: CONNECTION BROKEN?"
				        hasgoterror = true
				    end
    				sleep(1) # Slow down the event sniffer when we get errors
    			end
    		end
    	}

    	$EVENTSNIFFERCONNECTION.connection.enableEvents(false)

    end

public
    
	addHelpEntry("events", "dontSniffEvents", "", "", "This function stops the \
    	         events sniffer in CoolWatcher.")
    def dontSniffEvents()
    	$SNIFFEVENTTHREAD.kill
    end
    
    
    addHelpEntry("events", "sniffEvents", "", "", "This function displays \
                events received on the 'comport' COM port live in CoolWatcher.")
    def sniffEvents()
        printf("Event sniffer (re)starting. (Connection: %s)", $EVENTSNIFFERCONNECTION.connection.name)  
        sniffEventLoop()
    end
    
    addHelpEntry("events", "flushEvents", "", "", "This function remove all the \
                events in the event queue of the $EVENTSNIFFERCONNECTION.")
    def flushEvents()
        $EVENTSNIFFERCONNECTION.connection.flushEvents
    end
    
    addHelpEntry("events", "addEventSnifferCallBack", "event,lambdaBlock", "",
        "Adds a callback to the eventSniffer for the specific event \
        'event'. The lambdaBlock syntax is: *lambda { myRubyCode }* .")
    def addEventSnifferCallBack(event,lambdaBlock)
        @@callbacks[event] = lambdaBlock
    end
    
    def getEventSnifferCallBack(event)
        return @@callbacks[event]
    end
    
    addHelpEntry("events", "removeEventSnifferCallBack", "event", "",
        "Removes the callback of the eventSniffer installed \
        on the specific event 'event'.")
    def removeEventSnifferCallBack(event)
        @@callbacks.delete(event)
    end    

end

include EventSniffer
