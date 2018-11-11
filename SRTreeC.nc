#include "SimpleRoutingTree.h"
#ifdef PRINTFDBG_MODE
	#include "printf.h"
#endif

module SRTreeC
{
	uses interface Boot;
	uses interface SplitControl as RadioControl;

	uses interface Packet as RoutingPacket;
	uses interface AMSend as RoutingAMSend;
	uses interface AMPacket as RoutingAMPacket;
	

	uses interface Timer<TMilli> as RoutingMsgTimer;
	uses interface Timer<TMilli> as RoutingComplTimer;
	uses interface Timer<TMilli> as DistrMsgTimer;
	uses interface Timer<TMilli> as LostTaskTimer;
	
	uses interface Receive as RoutingReceive;
	
	uses interface PacketQueue as RoutingSendQueue;
	uses interface PacketQueue as RoutingReceiveQueue;

	//KP edit
	uses interface Packet as DistrPacket;
	uses interface AMSend as DistrAMSend;
	uses interface AMPacket as DistrAMPacket;

	uses interface PacketQueue as DistrSendQueue;
	uses interface PacketQueue as DistrReceiveQueue;
	uses interface Receive as DistrReceive;
}
implementation
{
	uint16_t  roundCounter;
	
	message_t radioRoutingSendPkt;
	//KP Edit
	message_t radioDistrSendPkt;
	
	message_t serialPkt;
	
	bool RoutingSendBusy=FALSE;
	
	bool lostRoutingSendTask=FALSE;
	bool lostRoutingRecTask=FALSE;
	
	uint8_t curdepth;
	uint16_t parentID;
	uint8_t i;

	//KP Edit
	/** Create Array of type ChildDristrMsg*/
	ChildDistrMsg childrenArray[MAX_CHILDREN];
	
	task void sendRoutingTask();
	task void receiveRoutingTask();
	task void sendDistrTask();
	task void receiveDistrTask();
	
	void setLostRoutingSendTask(bool state)
	{
		atomic{
			lostRoutingSendTask=state;
		}
		
	}
	
	void setLostRoutingRecTask(bool state)
	{
		atomic{
		lostRoutingRecTask=state;
		}
	}
	void setRoutingSendBusy(bool state)
	{
		atomic{
		RoutingSendBusy=state;
		}
		
	}

	/**Initialize children array with default values. Don't initialize max field because we don't know how the nodes are used and the max/min value*/
	void InitChildrenArray()
	{
		//uint8_t i;
		for(i=0; i< MAX_CHILDREN; i++){
			childrenArray[i].senderID = -1;
			childrenArray[i].sum = 0;
			childrenArray[i].count = 0;
		}
		
	}

	uint8_t maxFinder(uint16_t a, uint16_t b){
		return (a > b) ? a : b;
	}
	

	event void Boot.booted()
	{
		/////// arxikopoiisi radio kai serial
		call RadioControl.start();
		
		setRoutingSendBusy(FALSE);

		roundCounter =0;
		
		if(TOS_NODE_ID==0)
		{
			curdepth=0;
			parentID=0;
			dbg("Boot", "curdepth = %d  ,  parentID= %d \n", curdepth , parentID);
		}
		else
		{
			curdepth=-1;
			parentID=-1;
			dbg("Boot", "curdepth = %d  ,  parentID= %d \n", curdepth , parentID);
		}
	}
	
	event void RadioControl.startDone(error_t err)
	{
		if (err == SUCCESS)
		{
			dbg("Radio" , "Radio initialized successfully!!!\n");
			
			/**In case the radio was activated successfully then initialize children array */
			InitChildrenArray();

			call RoutingComplTimer.startOneShot(5000);
			
			if (TOS_NODE_ID==0)
			{
				
				call RoutingMsgTimer.startOneShot(TIMER_FAST_PERIOD);
				//call RoutingComplTimer.startOneShot(5000);
			}
		}
		else
		{
			dbg("Radio" , "Radio initialization failed! Retrying...\n");
			call RadioControl.start();
		}
	}
	
	event void RadioControl.stopDone(error_t err)
	{ 
		dbg("Radio", "Radio stopped!\n");

	}

	event void RoutingComplTimer.fired(){
		dbg("SRTreeC" , "Finished Rounting in cur node\n");
		dbg("SRTreeC" , "NodeID = %d, curdepth = %d getNow = %f , gett0 = %f", TOS_NODE_ID, curdepth,RoutingComplTimer.getNow, RoutingComplTimer.gett0 );
		//call DistrMsgTimer
	}

	event void LostTaskTimer.fired()
	{
		if (lostRoutingSendTask)
		{
			post sendRoutingTask();
			setLostRoutingSendTask(FALSE);
		}
		
		
		if (lostRoutingRecTask)
		{
			post receiveRoutingTask();
			setLostRoutingRecTask(FALSE);
		}
		
}

	
	event void RoutingMsgTimer.fired()
	{
		message_t tmp;
		error_t enqueueDone;
		
		RoutingMsg* mrpkt;
		dbg("SRTreeC", "RoutingMsgTimer fired!  radioBusy = %s \n",(RoutingSendBusy)?"True":"False");

		// if (TOS_NODE_ID==0)
		// {
		// 	roundCounter+=1;
			
		// 	dbg("SRTreeC", "\n ##################################### \n");
		// 	dbg("SRTreeC", "#######   ROUND   %u    ############## \n", roundCounter);
		// 	dbg("SRTreeC", "#####################################\n");
			
		// 	//call RoutingMsgTimer.startOneShot(TIMER_PERIOD_MILLI);
		// }
		
		if(call RoutingSendQueue.full())
		{
			dbg("SRTreeC", "RoutingSendQueue is FULL!!! \n");
			return;
		}
		
		
		mrpkt = (RoutingMsg*) (call RoutingPacket.getPayload(&tmp, sizeof(RoutingMsg)));
		if(mrpkt==NULL)
		{
			dbg("SRTreeC","RoutingMsgTimer.fired(): No valid payload... \n");
			return;
		}
		atomic{
		mrpkt->senderID=TOS_NODE_ID;
		mrpkt->depth = curdepth;
		}
		dbg("SRTreeC" , "Sending RoutingMsg... \n");
		
		call RoutingAMPacket.setDestination(&tmp, AM_BROADCAST_ADDR);
		call RoutingPacket.setPayloadLength(&tmp, sizeof(RoutingMsg));
		
		enqueueDone=call RoutingSendQueue.enqueue(tmp);
		
		if( enqueueDone==SUCCESS)
		{
			if (call RoutingSendQueue.size()==1)
			{
				dbg("SRTreeC", "SendTask() posted!!\n");
				post sendRoutingTask();
			}
			
			dbg("SRTreeC","RoutingMsg enqueued successfully in SendingQueue!!!\n");
		}
		else
		{
			dbg("SRTreeC","RoutingMsg failed to be enqueued in SendingQueue!!!");
		}		
	}

	event void RoutingAMSend.sendDone(message_t * msg , error_t err)
	{
		dbg("SRTreeC", "A Routing package sent... %s \n",(err==SUCCESS)?"True":"False");

		
		dbg("SRTreeC" , "Package sent %s \n", (err==SUCCESS)?"True":"False");

		setRoutingSendBusy(FALSE);
		
		if(!(call RoutingSendQueue.empty()))
		{
			post sendRoutingTask();
		}
	
		
	}

	//based on RoutingMsgTimer
	event void DistrMsgTimer.fired()
	{
		message_t tmp;
		error_t enqueueDone;
		uint16_t randVal;
		
		//RoutingMsg* mrpkt;
		DistrMsg* mrpkt;
		//dbg("SRTreeC", "RoutingMsgTimer fired!  radioBusy = %s \n",(RoutingSendBusy)?"True":"False");

		//TODO something afterwards
		// if (TOS_NODE_ID==0)
		// {
		// 	roundCounter+=1;
			
		// 	dbg("SRTreeC", "\n ##################################### \n");
		// 	dbg("SRTreeC", "#######   ROUND   %u    ############## \n", roundCounter);
		// 	dbg("SRTreeC", "#####################################\n");
			
		// 	call RoutingMsgTimer.startOneShot(TIMER_PERIOD_MILLI);
		// }
		
		//if(call RoutingSendQueue.full())
		if(call DistrSendQueue.full())
		{
			dbg("SRTreeC", "DistrSendQueue is FULL!!! \n");
			return;
		}
		
		
		//mrpkt = (RoutingMsg*) (call RoutingPacket.getPayload(&tmp, sizeof(RoutingMsg)));
		mrpkt = (DistrMsg*) (call DistrPacket.getPayload(&tmp, sizeof(DistrMsg)));
		if(mrpkt==NULL)
		{
			dbg("SRTreeC","DistrMsgTimer.fired(): No valid payload... \n");
			return;
		}

		//TODO
		//make it random and initialize it
		randVal = 5;

		//TODO fix fields used
		atomic{
		// mrpkt->senderID=TOS_NODE_ID;
		// mrpkt->depth = curdepth;
		mrpkt->sum = randVal;
		mrpkt->count = 1;
		mrpkt->max = randVal;

		//TODO check statements
		//uint8_t j;

		for(i = 0 ;i < MAX_CHILDREN ; i++){
			mrpkt->count += childrenArray[i].count;
			mrpkt->sum += childrenArray[i].sum;
			mrpkt->max += maxFinder(childrenArray[i].max, mrpkt->max);
		}

		//mrpkt->senderID = TOS_NODE_ID;

		}


	
		/** root case print everything*/
		if(TOS_NODE_ID == 0){
			roundCounter++;

			dbg("SRTreeC", "###Epoch %d completed###", roundCounter);
			dbg("SRTreeC", "Output: [count] = %d, [sum] = %d, [max] = %d, [avg] = %f", mrpkt->count, mrpkt->sum, mrpkt->max, mrpkt->sum / mrpkt->count);
		}
		else /** case we don't have root node then sent everything to the parent*/
		{

			dbg("SRTreeC", "Epoch: %d, Node: %d , Parent: %d, Sum: %d, count: %d, max: %d , depth: %d\n", roundCounter, TOS_NODE_ID,parentID, mrpkt->sum, mrpkt->count, mrpkt->max, curdepth);
			call DistrAMPacket.setDestination(&tmp, parentID);
			call DistrPacket.setPayloadLength(&tmp, sizeof(DistrMsg));

			enqueueDone=call DistrSendQueue.enqueue(tmp);

			if( enqueueDone==SUCCESS)
			{
				if (call DistrSendQueue.size()==1)
				{
					dbg("SRTreeC", "SendTask() posted!!\n");
					//TODO fix sendDistrTask()
					post sendDistrTask();
				}
			
				dbg("SRTreeC","DistrMsg enqueued successfully in SendingQueue!!!\n");
			}
			else
			{
				dbg("SRTreeC","DistrMsg failed to be enqueued in SendingQueue!!!");
			}

		}		
	}

	//TODO Change (add from task)RoutingAMSend to DistrAm
	event void DistrAMSend.sendDone(message_t * msg , error_t err)
	{
		dbg("SRTreeC", "A Distribution package sent... %s \n",(err==SUCCESS)?"True":"False");

		//setRoutingSendBusy(FALSE);
		
		if(!(call RoutingSendQueue.empty()))
		{
			post sendDistrTask();
		}
	
		
	}

	event message_t* DistrReceive.receive( message_t* msg , void* payload , uint8_t len)
	{
		error_t enqueueDone;
		message_t tmp;
		uint16_t msource;
		
		msource = call DistrAMPacket.source(msg);
		
		dbg("SRTreeC", "### DistrReceive.receive() start ##### \n");
		//TODO check
		//dbg("SRTreeC", "Something received!!!  from %u   %u \n",((DistrMsg*) payload)->senderID, msource);

		//if(len!=sizeof(NotifyParentMsg))
		//{
			//dbg("SRTreeC","\t\tUnknown message received!!!\n");
//#ifdef PRINTFDBG_MODE
			//printf("\t\t Unknown message received!!!\n");
			//printfflush();
//#endif
			//return msg;http://courses.ece.tuc.gr/
		//}
		
		atomic{
		memcpy(&tmp,msg,sizeof(message_t));
		//tmp=*(message_t*)msg;
		}
		enqueueDone=call DistrReceiveQueue.enqueue(tmp);
		
		if( enqueueDone== SUCCESS)
		{
			dbg("SRTreeC","posting receiveDistrTask()!!!! \n");
			post receiveDistrTask();
		}
		else
		{
			dbg("SRTreeC","DistrMsg enqueue failed!!! \n");
			
		}
		
		dbg("SRTreeC", "### DistrReceive.receive() end ##### \n");
		return msg;
	}
	
	
//	event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len)
	event message_t* RoutingReceive.receive( message_t * msg , void * payload, uint8_t len)
	{
		error_t enqueueDone;
		message_t tmp;
		uint16_t msource;
		
		msource =call RoutingAMPacket.source(msg);
		
		dbg("SRTreeC", "### RoutingReceive.receive() start ##### \n");
		dbg("SRTreeC", "Something received!!!  from %u  %u \n",((RoutingMsg*) payload)->senderID ,  msource);
		//dbg("SRTreeC", "Something received!!!\n");
		//call Leds.led1On();
		//call Led1Timer.startOneShot(TIMER_LEDS_MILLI);
		
		//if(len!=sizeof(RoutingMsg))
		//{
			//dbg("SRTreeC","\t\tUnknown message received!!!\n");
//#ifdef PRINTFDBG_MODE
			//printf("\t\t Unknown message received!!!\n");
			//printfflush();
//#endif
			//return msg;
		//}
		
		atomic{
		memcpy(&tmp,msg,sizeof(message_t));
		//tmp=*(message_t*)msg;
		}
		enqueueDone=call RoutingReceiveQueue.enqueue(tmp);
		if(enqueueDone == SUCCESS)
		{
			dbg("SRTreeC","posting receiveRoutingTask()!!!! \n");
			post receiveRoutingTask();
		}
		else
		{
			dbg("SRTreeC","RoutingMsg enqueue failed!!! \n");			
		}
		
		//call Leds.led1Off();
		
		dbg("SRTreeC", "### RoutingReceive.receive() end ##### \n");
		return msg;
	}
	
	
	////////////// Tasks implementations //////////////////////////////
	
	
	task void sendRoutingTask()
	{
		//uint8_t skip;
		uint8_t mlen;
		uint16_t mdest;
		error_t sendDone;
		//message_t radioRoutingSendPkt;
		dbg("SRTreeC","SendRoutingTask(): Starting....\n");
		if (call RoutingSendQueue.empty())
		{
			dbg("SRTreeC","sendRoutingTask(): Q is empty!\n");
			return;
		}
		
		
		if(RoutingSendBusy)
		{
			dbg("SRTreeC","sendRoutingTask(): RoutingSendBusy= TRUE!!!\n");
			setLostRoutingSendTask(TRUE);
			return;
		}
		
		radioRoutingSendPkt = call RoutingSendQueue.dequeue();
		
		//call Leds.led2On();
		//call Led2Timer.startOneShot(TIMER_LEDS_MILLI);
		mlen= call RoutingPacket.payloadLength(&radioRoutingSendPkt);
		mdest=call RoutingAMPacket.destination(&radioRoutingSendPkt);
		if(mlen!=sizeof(RoutingMsg))
		{
			dbg("SRTreeC","\t\tsendRoutingTask(): Unknown message!!!\n");

			return;
		}
		sendDone=call RoutingAMSend.send(mdest,&radioRoutingSendPkt,mlen);
		
		if ( sendDone== SUCCESS)
		{
			dbg("SRTreeC","sendRoutingTask(): Send returned success!!!\n");
			setRoutingSendBusy(TRUE);
		}
		else
		{
			dbg("SRTreeC","send failed!!!\n");

			//setRoutingSendBusy(FALSE);
		}
	}
	

	task void sendDistrTask()
	{
		uint8_t mlen;//, skip;
		error_t sendDone;
		uint16_t mdest;
		DistrMsg* mpayload;
		
		dbg("SRTreeC","SendDistrTask(): going to send one more package.\n");

		if (call DistrSendQueue.empty())
		{
			dbg("SRTreeC","sendDistrTask(): Q is empty!\n");
			return;
		}
		
		//TODO create that
		// if(NotifySendBusy==TRUE)
		// {
		// 	dbg("SRTreeC","sendNotifyTask(): NotifySendBusy= TRUE!!!\n");

		// 	setLostNotifySendTask(TRUE);
		// 	return;
		// }
		
		radioDistrSendPkt = call DistrSendQueue.dequeue();
		
		mlen=call DistrPacket.payloadLength(&radioDistrSendPkt);
		
		mpayload= call DistrPacket.getPayload(&radioDistrSendPkt,mlen);
		
		if(mlen!= sizeof(DistrMsg))
		{
			dbg("SRTreeC", "\t\t sendDistrTask(): Unknown message!!\n");
			return;
		}
		
		//TODO check that
		//dbg("SRTreeC" , " sendDistrTask(): mlen = %u  senderID= %u \n",mlen,mpayload->senderID);

		mdest= call DistrAMPacket.destination(&radioDistrSendPkt);
		
		
		sendDone=call DistrAMSend.send(mdest,&radioDistrSendPkt, mlen);
		
		if ( sendDone== SUCCESS)
		{
			dbg("SRTreeC","sendDistrTask(): Send returned success!!!\n");

			//setNotifySendBusy(TRUE);
		}
		else
		{
			dbg("SRTreeC","sendDistrTask(): Send returned failed!!!\n");

		}
	}

	////////////////////////////////////////////////////////////////////
	//*****************************************************************/
	///////////////////////////////////////////////////////////////////
	/**
	 * dequeues a message and processes it
	 */
	
	task void receiveRoutingTask()
	{
		message_t tmp;
		uint8_t len;
		message_t radioRoutingRecPkt;
		
		dbg("SRTreeC","ReceiveRoutingTask():received msg...\n");

		radioRoutingRecPkt= call RoutingReceiveQueue.dequeue();
		
		len= call RoutingPacket.payloadLength(&radioRoutingRecPkt);
		
		dbg("SRTreeC","ReceiveRoutingTask(): len=%u \n",len);

		// processing of radioRecPkt
		
		// pos tha xexorizo ta 2 diaforetika minimata???
				
		if(len == sizeof(RoutingMsg))
		{
			//NotifyParentMsg* m;
			RoutingMsg * mpkt = (RoutingMsg*) (call RoutingPacket.getPayload(&radioRoutingRecPkt,len));
			
			//if(TOS_NODE_ID >0)
			//{
				//call RoutingMsgTimer.startOneShot(TIMER_PERIOD_MILLI);
			//}
			//
			dbg("SRTreeC" ,"NodeID= %d , RoutingMsg received! \n",TOS_NODE_ID);
			dbg("SRTreeC" , "receiveRoutingTask():senderID= %d , depth= %d \n", mpkt->senderID , mpkt->depth);

			if ( (parentID<0)||(parentID>=65535))
			{
				// tote den exei akoma patera
				parentID= call RoutingAMPacket.source(&radioRoutingRecPkt);//mpkt->senderID;q
				curdepth= mpkt->depth + 1;
				dbg("SRTreeC" ,"NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);

				// tha stelnei kai ena minima NotifyParentMsg ston patera
				
				// m = (NotifyParentMsg *) (call NotifyPacket.getPayload(&tmp, sizeof(NotifyParentMsg)));
				// m->senderID=TOS_NODE_ID;
				// m->depth = curdepth;
				// m->parentID = parentID;
				// dbg("SRTreeC" , "receiveRoutingTask():NotifyParentMsg sending to node= %d... \n", parentID);

				// call NotifyAMPacket.setDestination(&tmp, parentID);
				// call NotifyPacket.setPayloadLength(&tmp,sizeof(NotifyParentMsg));
				
				// if (call NotifySendQueue.enqueue(tmp)==SUCCESS)
				// {
				// 	dbg("SRTreeC", "receiveRoutingTask(): NotifyParentMsg enqueued in SendingQueue successfully!!!");

				// 	if (call NotifySendQueue.size() == 1)
				// 	{
				// 		post sendNotifyTask();
				// 	}
				// }
				if (TOS_NODE_ID!=0)
				{
					dbg("SRTreeC" ,"ALERT with NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);
					call RoutingMsgTimer.startOneShot(TIMER_FAST_PERIOD);
					//call RoutingComplTimer.startOneShot(0);
				}
			}
			 else
			 {
			 	dbg("SRTreeC" ,"Already have a parent with NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);
				}
			// 	if (( curdepth > mpkt->depth +1) || (mpkt->senderID==parentID))
			// 	{
			// 		uint16_t oldparentID = parentID;
					
				
			// 		parentID= call RoutingAMPacket.source(&radioRoutingRecPkt);//mpkt->senderID;
			// 		curdepth = mpkt->depth + 1;
			// 		dbg("SRTreeC" , "NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);				
									
					
			// 		dbg("SRTreeC" , "NotifyParentMsg sending to node= %d... \n", oldparentID);

			// 		if ( (oldparentID<65535) || (oldparentID>0) || (oldparentID==parentID))
			// 		{
			// 			m = (NotifyParentMsg *) (call NotifyPacket.getPayload(&tmp, sizeof(NotifyParentMsg)));
			// 			m->senderID=TOS_NODE_ID;
			// 			m->depth = curdepth;
			// 			m->parentID = parentID;
						
			// 			call NotifyAMPacket.setDestination(&tmp,oldparentID);
			// 			//call NotifyAMPacket.setType(&tmp,AM_NOTIFYPARENTMSG);
			// 			call NotifyPacket.setPayloadLength(&tmp,sizeof(NotifyParentMsg));
								
			// 			if (call NotifySendQueue.enqueue(tmp)==SUCCESS)
			// 			{
			// 				dbg("SRTreeC", "receiveRoutingTask(): NotifyParentMsg enqueued in SendingQueue successfully!!!\n");

			// 				if (call NotifySendQueue.size() == 1)
			// 				{
			// 					post sendNotifyTask();
			// 				}
			// 			}
			// 		}
			// 		if (TOS_NODE_ID!=0)
			// 		{
			// 			call RoutingMsgTimer.startOneShot(TIMER_FAST_PERIOD);
			// 		}
			// 		// tha stelnei kai ena minima NotifyParentMsg 
			// 		// ston kainourio patera kai ston palio patera.
					
			// 		if (oldparentID!=parentID)
			// 		{
			// 			m = (NotifyParentMsg *) (call NotifyPacket.getPayload(&tmp, sizeof(NotifyParentMsg)));
			// 			m->senderID=TOS_NODE_ID;
			// 			m->depth = curdepth;
			// 			m->parentID = parentID;
			// 			dbg("SRTreeC" , "receiveRoutingTask():NotifyParentMsg sending to node= %d... \n", parentID);

			// 			call NotifyAMPacket.setDestination(&tmp, parentID);
			// 			call NotifyPacket.setPayloadLength(&tmp,sizeof(NotifyParentMsg));
						
			// 			if (call NotifySendQueue.enqueue(tmp)==SUCCESS)
			// 			{
			// 				dbg("SRTreeC", "receiveRoutingTask(): NotifyParentMsg enqueued in SendingQueue successfully!!! \n");

			// 				if (call NotifySendQueue.size() == 1)
			// 				{
			// 					post sendNotifyTask();
			// 				}
			// 			}
			// 		}
			// 	}
				
				
			// }
		}
		else
		{
			dbg("SRTreeC","receiveRoutingTask():Empty message!!! \n");

			setLostRoutingRecTask(TRUE);
			return;
		}
		
	}


	/** Based on receiveNotifyTask()*/
	task void receiveDistrTask()
	{
		message_t tmp;
		uint8_t len;
		uint8_t source;
		message_t radioDistrRecPkt;
		
		dbg("SRTreeC","ReceiveDistrTask():received msg...\n");

		radioDistrRecPkt= call DistrReceiveQueue.dequeue();
		
		len= call DistrPacket.payloadLength(&radioDistrRecPkt);

		//TODO check that
		source = call DistrAMPacket.source(&radioDistrSendPkt);
		
		dbg("SRTreeC","ReceiveDistrTask(): len=%u \n",len);

		if(len == sizeof(DistrMsg))
		{
			// an to parentID== TOS_NODE_ID tote
			// tha proothei to minima pros tin riza xoris broadcast
			// kai tha ananeonei ton tyxon pinaka paidion..
			// allios tha diagrafei to paidi apo ton pinaka paidion
			
			DistrMsg* mr = (DistrMsg*) (call DistrPacket.getPayload(&radioDistrRecPkt,len));
			//uint8_t i
			for(i=0; i< MAX_CHILDREN ; i++){
				if(source == childrenArray[i].senderID){
					childrenArray[i].count = mr->count;
					childrenArray[i].sum = mr->sum;
					childrenArray[i].max = mr->max;
					break;

				}else{
					dbg("SRTreeC", "#############SOMETHING........");
				}
			}
			
			
			//TODO CHECK THAT
			//dbg("SRTreeC" , "DistrParentMsg received from %d !!! \n", mr->senderID);

			//TODO CHECK THAT
			// if ( mr->parentID == TOS_NODE_ID)
			// {
			// 	// tote prosthiki stin lista ton paidion.
				
			// }
			// else
			// {
			// 	// apla diagrafei ton komvo apo paidi tou..
				
			// }
			// if ( TOS_NODE_ID==0)
			// {


			// }
			// else
			// {
			// 	DistrMsg* m;
			// 	memcpy(&tmp,&radioDistrRecPkt,sizeof(message_t));
				
			// 	m = (DistrMsg *) (call DistrPacket.getPayload(&tmp, sizeof(DistrMsg)));
			// 	//m->senderID=mr->senderID;
			// 	//m->depth = mr->depth;
			// 	//m->parentID = mr->parentID;
				
			// 	//TODO chech that
			// 	//dbg("SRTreeC" , "Forwarding DistrParentMsg from senderID= %d  to parentID=%d \n" , m->senderID, parentID);

			// 	call DistrAMPacket.setDestination(&tmp, parentID);
			// 	call DistrPacket.setPayloadLength(&tmp,sizeof(DistrMsg));
				
			// 	if (call DistrSendQueue.enqueue(tmp)==SUCCESS)
			// 	{
			// 		dbg("SRTreeC", "receiveDistrTask(): DistrParentMsg enqueued in SendingQueue successfully!!!\n");
			// 		if (call DistrSendQueue.size() == 1)
			// 		{
			// 			post sendDistrTask();
			// 		}
			// 	}

				
			// }
			
		}
		else
		{
			dbg("SRTreeC","receiveDistrTask():Empty message!!! \n");
			//setLostNotifyRecTask(TRUE);
			return;
		}
		
	}
	 
	
}
