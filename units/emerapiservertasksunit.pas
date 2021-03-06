unit EmerAPIServerTasksUnit;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, EmerAPIMain, emerapitypes, EmerAPIBlockchainUnit, fpjson;

type
tEmerAPIServerTaskValid=(eptvUnknown,eptvValid,eptvInvalid,eptvPart); //part for a group means some tasks are valid

tEmerAPIServerTaskList=class;

tBaseEmerAPIServerTask=class(tObject)
  protected
    fEmerAPI:tEmerAPI;
    fExecuted:boolean; //sent to BC. Will be removed by parent
    fExecutionDatetime:tDatetime;
    fSuccessful:boolean; //set together with fExecuted
    fOwner:tEmerAPIServerTaskList;
    fOnDone:tNotifyEvent; //called if the task is done (sent to BC, for example, even not successeful)
    fLastError:string;

    fTaskValid:boolean; //is the task CAN be applied?
    fTaskValidAt:tDateTime; //0 if not checked; etherwise time

    function execute(onDone:tNotifyEvent=nil):boolean; virtual;
    function getExecuted:boolean; virtual; abstract; //for task: it was send. for group: all the tasks were sent
  public
    fUpdated:boolean; //set true on data loaded. One time.

    userObj1:tObject;
    Comment:string;  //comment: String
    id:ansistring; //id: ID
    NVSName:ansistring; //name: String
    NVSValue:ansistring; //value
    NVSDays:qword;
    amount:qword;   //amount: Float
    ownerAddress:ansistring; //address
    time:dword;
    LockTime:dword;
    //  dpo: String
    //  time: Int
    TaskType: String; //type

    onTaskUpdated:tNotifyEvent;

    //
    function getDescription:string;  virtual; abstract;
    function fIsKnownName:boolean; virtual; abstract; //рекурсивно вызывает всех детей, если есть. Возвращает типировано ли имя
    function getTitle:string;  virtual; abstract;
    function getNameType:ansistring; virtual; abstract;//Возвращает имя с сигнатурой, например 'dns' или 'af:brand'

    procedure validateTask(); virtual; abstract;

    //stat
    function getCost:qWord; virtual; abstract;

    function getValid:tEmerAPIServerTaskValid; virtual; abstract;

    //  group: ссылка на группу, при запросе можно получать поля, например id
    property Executed:boolean read getExecuted;
    property Successful:boolean read fSuccessful;
    property LastError:string read fLastError;

    constructor create(mOwner:tEmerAPIServerTaskList);
end;

tEmerAPIServerTask=class(tBaseEmerAPIServerTask)
 private
   procedure SendingError(Sender: TObject);
   procedure Sent(Sender: TObject);

   //procedure onAsyncQueryDoneHandler(sender:TEmerAPIBlockchainThread;result:tJsonData);
   procedure onAsyncQueryDoneHandler(sender:TEmerAPIBlockchainThread;result:tJsonData);
 public
   function getEmerAPI:tEmerAPI;
   function getValid:tEmerAPIServerTaskValid; override;
   procedure validateTask(); override;
   procedure updateDataByParent(); //updates fields by parent task
   function execute(onDone:tNotifyEvent=nil):boolean; override;
   function getExecuted:boolean; override;
   function getCost:qWord; override;
end;

tEmerAPIServerTaskGroup=class(tBaseEmerAPIServerTask)
 private
  function getCount:integer;
  function getItem(Index: integer):tBaseEmerAPIServerTask;
  procedure taskExecuted(sender: tObject);
 protected
   Tasks:tEmerAPIServerTaskList;
 public
   property Count:integer read getCount;
   property Items[Index: integer]:tBaseEmerAPIServerTask read getItem; default;

   property getTasks:tEmerAPIServerTaskList read Tasks;

   function execute(onDone:tNotifyEvent=nil):boolean; override;
   function getExecuted:boolean; override;
   constructor create(mOwner:tEmerAPIServerTaskList);
   destructor destroy; override;

   function getValid:tEmerAPIServerTaskValid; override;
   procedure validateTask(); override;
   //stat
   function getCost:qWord; override;
   function getUniOwnerCount:integer;
   function getOwnerByCount(address:ansistring='undefined'):integer;
end;

//update
//error
//newtask
//taskremoved
//taskUpdated  : single task has new information
tEmerAPIServerTaskList=class(tEmerApiNotified)
private
  fOwnerTask:tBaseEmerAPIServerTask;
  fEmerAPI:tEmerAPI;
  fLastUpdateTime:tDatetime;
  fItems:tList;
  fValidateAfterCreate:boolean;
  function getItem(Index: integer):tBaseEmerAPIServerTask;
  function getCount:integer;
  procedure clearList;
  procedure onAsyncQueryDoneHandler(sender:TEmerAPIBlockchainThread;result:tJsonData);
  procedure myUpdate(sender:tObject);
  procedure myError(sender:tObject);
  procedure myNewTask(sender:tObject);
  procedure myTaskRemoved(sender:tObject);
  procedure mytaskUpdated(sender:tObject);
public
  property Count:integer read getCount;
  property Items[Index: integer]:tBaseEmerAPIServerTask read getItem; default;
  property ValidateAfterCreate:boolean read fValidateAfterCreate write fValidateAfterCreate;
  procedure delete(Index: integer);
  procedure validateTask(Index:integer=-1); //-1 for all
  procedure updateFromServer(groupID:ansistring='');
  constructor create(mEmerAPI:tEmerAPI; setValidateAfterCreate:boolean=true);
  destructor destroy; override;
end;


implementation

uses HelperUnit, EmerAPITransactionUnit, MainUnit{for getprivkey}, crypto, EmerTX, LazUTF8SysUtils;

{tBaseEmerAPIServerTask}
constructor tBaseEmerAPIServerTask.create(mOwner:tEmerAPIServerTaskList);
begin
 inherited create;
 fOwner:=mOwner;
 fLastError:='';
end;


function tBaseEmerAPIServerTask.execute(onDone:tNotifyEvent=nil):boolean;
begin
 fonDone:=onDone;
 fLastError:='';
 result:=true;
end;

{tEmerAPIServerTask}
function tEmerAPIServerTask.getCost:qWord;
begin
  result:=0;

end;

function tEmerAPIServerTask.getExecuted:boolean;
begin
 result:=fExecuted;
end;

function tEmerAPIServerTask.getValid:tEmerAPIServerTaskValid;
begin
 //eptvUnknown,eptvValid,eptvInvalid,eptvPart
 if fTaskValidAt>0 then
   if fTaskValid then
     result:=eptvValid
   else
     result:=eptvInvalid
 else begin
   result:=eptvUnknown;
 end;
end;

procedure tEmerAPIServerTask.onAsyncQueryDoneHandler(sender:TEmerAPIBlockchainThread;result:tJsonData);
var e:tJsonData;
    {s:string;
    val,x:double;
    nc,i,n:integer;
    st:ansistring;
    vR,vY,vS:double;
    nameScript:tNameScript;
    amount:integer;
    }
begin
 if result=nil then //requery? failed?
   exit; //ok. now just do nothing

 if sender.id=('checkname:'+trim(NVSName)) then begin
   e:=result.FindPath('result');
   if e<>nil then
      if e.IsNull then begin
        //name is free
        fTaskValidAt:=now;
        fTaskValid:=true;
        if assigned(fOwner) then fOwner.callNotify('taskUpdated');
      end else begin
        fTaskValidAt:=now;
        fTaskValid:=false;
        if assigned(fOwner) then fOwner.callNotify('taskUpdated');
      end
   else exit; //can't check //lNameExits.Caption:='Error: can''t find result in: '+result.AsJSON;
 end;

end;

procedure tEmerAPIServerTask.validateTask();
var nt:ansistring;
begin
 //check if the task is valid.
 //set fTaskValidAt and fTaskValid
{  if (NVSName='')
     or (NVSValue='')
     or (length(NVSName)>512)
     or (length(NVSValue)>20480)
     or (NVSDays<1)
     or (ownerAddress='')
     or ((time>1000000) and ((time<()) or (time>())))
     or ((LockTime>1000000) and ((LockTime<()) or (LockTime>())))
}
  if (ownerAddress='')
     or ((time>1000000) and ((time<(winTimeToUnixTime(nowUTC()))) or (time>(winTimeToUnixTime(nowUTC())+3000))))
     or ((LockTime>1000000) and ({(LockTime<(winTimeToUnixTime(nowUTC())-3000)) or} (LockTime>(winTimeToUnixTime(nowUTC())+3000*100))))
  then begin
     fTaskValidAt:=now;
     fTaskValid:=false;
     if assigned(fOwner) then fOwner.callNotify('taskUpdated');
     exit;
  end;

 if TaskType='NEW_NAME' then begin
   //create name. We must check if the name is not exists
   updateDataByParent;

   if (NVSName='')
     or (NVSValue='')
     or (length(NVSName)>512)
     or (length(NVSValue)>20480)
     or (NVSDays<1)
   then begin
     fTaskValidAt:=now;
     fTaskValid:=false;
     if assigned(fOwner) then fOwner.callNotify('taskUpdated');
     exit;
   end;
   //check

   getEmerAPI.EmerAPIConnetor.sendWalletQueryAsync('name_show',getJSON('{name:"'+NVSName+'"}'),@onAsyncQueryDoneHandler,'checkname:'+NVSName);


 end else begin//unknown task
   fTaskValidAt:=0;
   fTaskValid:=false;
 end;
end;

procedure tEmerAPIServerTask.SendingError(Sender: TObject);
begin
  //if Sender is tEmerTransaction
  //  then ShowMessageSafe('Sending error: '+tEmerTransaction(sender).lastError)
  //  else ShowMessageSafe('Sending error');
 fSuccessful:=false;
 fExecuted:=true;
 if Sender is tEmerTransaction
    then fLastError:=tEmerTransaction(sender).lastError
    else fLastError:='unknown sending error';

 if assigned(fonDone) then fonDone(self);
end;

procedure tEmerAPIServerTask.Sent(Sender: TObject);
begin
   //ShowMessageSafe('Successfully sent');
 fSuccessful:=true;
 fExecuted:=true;
 fLastError:='';

 if assigned(fonDone) then fonDone(self);
end;

procedure tEmerAPIServerTask.updateDataByParent();
begin
 {
 nName:=NVSName;
 nValue:=NVSValue;
 nDays:=NVSDays;
 nAmount:=amount;
 nOwnerAddress:=ownerAddress;
 nTime:=time;
 nLockTime:=LockTime;
  }
 if (fOwner<>nil) and (fOwner.fOwnerTask<>nil) then begin
   if fOwner.fOwnerTask.NVSName<>'' then NVSName:=fOwner.fOwnerTask.NVSName;
   if fOwner.fOwnerTask.NVSValue<>'' then NVSValue:=fOwner.fOwnerTask.NVSValue;
   if fOwner.fOwnerTask.NVSDays>0 then NVSDays:=fOwner.fOwnerTask.NVSDays;
   if fOwner.fOwnerTask.amount>0 then amount:=fOwner.fOwnerTask.amount;
   if fOwner.fOwnerTask.time<>-1 then time:=fOwner.fOwnerTask.time;
   if fOwner.fOwnerTask.LockTime<>-1 then LockTime:=fOwner.fOwnerTask.LockTime;
 end;

end;

function tEmerAPIServerTask.getEmerAPI:tEmerAPI;
begin
  result:=fEmerAPI;
  if result=nil then
     if (fOwner<>nil) then result:=fOwner.fEmerAPI;

  if result=nil then
     if (fOwner<>nil) and (fOwner.fOwnerTask<>nil) then
       result:=fOwner.fOwnerTask.fEmerAPI;

  if result=nil then raise exception.Create('tEmerAPIServerTask.execute: EmerAPI is nil');
end;

function tEmerAPIServerTask.execute(onDone:tNotifyEvent=nil):boolean;
var
    //nName,nValue:ansistring;
    //nDays,nAmount:qword;
    //nOwnerAddress:ansistring;
    //nTime:dWord;
    //nLockTime:dWord;
    tx:tEmerTransaction;
    EmerAPI:tEmerAPI;
begin
  inherited;//fonDone:=onDone;
  result:=false;

  EmerAPI:=getEmerAPI;


  {
  data:


  NVSName:ansistring;  - only for NAME_NEW, NAME_UPDATE, NAME_DELETE
  NVSValue:ansistring; - only for NAME_NEW, NAME_UPDATE
  NVSDays:qword;  - only for NAME_NEW, NAME_UPDATE
  amount:qword;  - only for payments.
  ownerAddress:ansistring; //address
  time:dword;
  LockTime:dword;
  }

  updateDataByParent;


  if TaskType='NEW_NAME' then begin
    if length(NVSName)>512 then exit;
    if length(NVSValue)>20480 then exit;

    tx:=tEmerTransaction.create(EmerAPI,true);

    if not( (time=-1) or (time=0)) then tx.Time:=time;
    if not( (LockTime=-1) or (LockTime=0)) then tx.LockTime:= LockTime;

    try
      tx.addOutput(tx.createNameScript(addressto21(ownerAddress),NVSName,NVSValue,NVSDays,True),EmerAPI.blockChain.MIN_TX_FEE);
         //EmerAPI.blockChain.getNameOpFee(seDays.Value,opNum('OP_NAME_NEW'),length(nName)+length(nValue))
      if tx.makeComplete then begin
        if tx.signAllInputs(MainForm.PrivKey) then begin
          tx.sendToBlockchain(EmerAPINotification(@Sent,'sent'));
          tx.addNotify(EmerAPINotification(@SendingError,'error'));
        end else begin fLastError:=('Can''t sign all transaction inputs using current key: '+tx.LastError); freeandnil(tx); exit; end;//else showMessageSafe('Can''t sign all transaction inputs using current key: '+tx.LastError);
      end else begin fLastError:=('Can''t create transaction: '+tx.LastError); freeandnil(tx); exit; end; //showMessageSafe('Can''t create transaction: '+tx.LastError);
    except
      freeandnil(tx);
      exit;
    end;
    result:=true;
  end;
end;


{tEmerAPIServerTaskGroup}
function tEmerAPIServerTaskGroup.getCount:integer;
begin
 result:=0;
 if Tasks=nil then exit;
 result:=Tasks.Count;
end;

function tEmerAPIServerTaskGroup.getItem(Index: integer):tBaseEmerAPIServerTask;
begin
 result:=nil;
 if Tasks=nil then exit;
 result:=Tasks[Index];
end;

procedure tEmerAPIServerTaskGroup.taskExecuted(sender: tObject);
var i:integer;
    mySuccessful:boolean;
begin

 fSuccessful:=false;
 mySuccessful:=true;
 for i:=0 to Tasks.Count-1 do begin
   if not tBaseEmerAPIServerTask(Tasks[i]).Executed then exit;
   mySuccessful:= mySuccessful and tBaseEmerAPIServerTask(Tasks[i]).Successful;
   if not tBaseEmerAPIServerTask(Tasks[i]).Successful then
    fLastError:= fLastError + tBaseEmerAPIServerTask(Tasks[i]).LastError+'; ';
 end;

 fSuccessful:=mySuccessful;

 if not assigned(fOnDone) then exit;
 fOnDone(self);
end;

function tEmerAPIServerTaskGroup.execute(onDone:tNotifyEvent=nil):boolean;
var i:integer;
begin
 inherited;
 result:=true;
 for i:=0 to Tasks.Count-1 do
   if tBaseEmerAPIServerTask(Tasks[i]).getValid in [eptvValid,eptvPart] then
     if not tBaseEmerAPIServerTask(Tasks[i]).Execute(@taskExecuted)
       then result:=false;

end;

procedure tEmerAPIServerTaskGroup.validateTask();
begin
  Tasks.validateTask(-1);
end;

function tEmerAPIServerTaskGroup.getValid:tEmerAPIServerTaskValid;
var i:integer;
    ceptvValid,ceptvInvalid:integer;
begin
 result:=eptvUnknown;

 //eptvUnknown,eptvValid,eptvInvalid,eptvPart

 ceptvValid:=0;
 ceptvInvalid:=0;
 for i:=0 to Tasks.Count-1 do
   case tBaseEmerAPIServerTask(Tasks[i]).getValid of
     eptvUnknown:exit;
     eptvValid:inc(ceptvValid);
     eptvInvalid:inc(ceptvInvalid);
   end;
 if ceptvValid*ceptvInvalid>0 then result:=eptvPart
    else if ceptvValid>0 then result:=eptvValid
    else if ceptvInvalid>0 then result:=eptvInvalid;
 //else just unknown or erroneous state
end;

function tEmerAPIServerTaskGroup.getExecuted:boolean;
var i:integer;
begin
  result:=false;
  for i:=0 to Tasks.Count-1 do
    if not tBaseEmerAPIServerTask(Tasks[i]).Executed
      then exit;
  result:=true;
end;

function tEmerAPIServerTaskGroup.getCost:qWord;
var i:integer;
begin
  result:=0;
  for i:=0 to Tasks.Count-1 do
    result:=result + tBaseEmerAPIServerTask(Tasks[i]).getCost;
end;

function tEmerAPIServerTaskGroup.getUniOwnerCount:integer;
var i:integer;
    nl:tStringList;
begin
 result:=0;
 if Tasks.Count=1 then begin
    result:=1;
    exit;
 end;

 nl:=tStringList.Create;
 try
 for i:=0 to Tasks.Count-1 do
   if nl.IndexOf(tBaseEmerAPIServerTask(Tasks[i]).ownerAddress)<0 then begin
      nl.Add(tBaseEmerAPIServerTask(Tasks[i]).ownerAddress);
      result:=result + 1;
   end;
 finally
   nl.free;
 end;
end;

function tEmerAPIServerTaskGroup.getOwnerByCount(address:ansistring='undefined'):integer;
var i:integer;
begin
  result:=0;
  for i:=0 to Tasks.Count-1 do
    if tBaseEmerAPIServerTask(Tasks[i]).ownerAddress=address then
       result:=result + 1;
end;


constructor tEmerAPIServerTaskGroup.create(mOwner:tEmerAPIServerTaskList);
begin
 inherited create(mOwner);
 Tasks:=tEmerAPIServerTaskList.create(fOwner.fEmerApi);

 Tasks.fOwnerTask:=self;
 //update
//error
//newtask
//taskremoved
//taskUpdated
 Tasks.addNotify(EmerAPINotification(@(fOwner.myUpdate),'update',true));
 Tasks.addNotify(EmerAPINotification(@(fOwner.myError),'error',true));
 Tasks.addNotify(EmerAPINotification(@(fOwner.myNewTask),'newtask',true));
 Tasks.addNotify(EmerAPINotification(@(fOwner.myTaskRemoved),'taskremoved',true));
 Tasks.addNotify(EmerAPINotification(@(fOwner.mytaskUpdated),'taskUpdated',true));


end;

destructor tEmerAPIServerTaskGroup.destroy;
begin
  freeandnil(Tasks);
  inherited;
end;


{tEmerAPIServerTaskList}
procedure tEmerAPIServerTaskList.myUpdate(sender:tObject);
var i:integer;
begin
  //if ALL tasks are updated, call Update notify
  for i:=0 to Count-1 do
    if not Items[i].fUpdated then exit;;


  //set parent group task updated = true
  if fOwnerTask<>nil then
     fOwnerTask.fUpdated:=true;

  //call notification
  callNotify('update');

end;

procedure tEmerAPIServerTaskList.myError(sender:tObject);
begin
  callNotify('error');
end;

procedure tEmerAPIServerTaskList.myNewTask(sender:tObject);
begin
  callNotify('newtask')
end;

procedure tEmerAPIServerTaskList.myTaskRemoved(sender:tObject);
begin
 callNotify('taskremoved')
end;

procedure tEmerAPIServerTaskList.mytaskUpdated(sender:tObject);
begin
 callNotify('taskUpdated')
end;


procedure tEmerAPIServerTaskList.onAsyncQueryDoneHandler(sender:TEmerAPIBlockchainThread;result:tJsonData);
var js,e:tJsonData;
    ja:tJSONArray;
    s:string;
    x:double;
    i,j:integer;
    st:ansistring;

    groupID:ansistring;
    taskID:ansistring;

    task:tEmerAPIServerTask;
    group:tEmerAPIServerTaskGroup;
    q:qword;

    taskidx:integer;

    function safeString(e:tJsonData):string;
    begin
     if e<>nil then
        if e.IsNull
         then result:=''
         else result:=e.asString
     else result:='';
    end;


begin
  if result=nil then begin
   fEmerAPI.EmerAPIConnetor.checkConnection();
   exit;
  end;

  js:=result;
  if pos('transactiongrouplist_',sender.id+'_')=1 then begin
    //this is a main list
   //{ "data" : { "transactiongrouplist" : [{ "address" : "address", "amount" : 1. ......
    if js<>nil then begin
     e:=js.FindPath('data.transactiongrouplist');
     if (e<>nil) and (e is tJSONArray) then begin
        ja:=tJSONArray(e);
        for i:=0 to ja.Count-1 do begin
          //group. Do we have it?
          groupID:=ja[i].FindPath('id').AsString;
          group:=nil;
          for j:=0 to Count-1 do
            if items[j] is tEmerAPIServerTaskGroup then
               if uppercase(tEmerAPIServerTaskGroup(items[j]).id) =uppercase(groupID) then begin
                  group:=tEmerAPIServerTaskGroup(items[j]);
                  break;
               end;

          if group = nil then begin
            group:=tEmerAPIServerTaskGroup.create(self);
            fItems.add(group);
            //Comment:string;  //comment: String
            group.Comment:=safeString(ja[i].FindPath('comment'));
            //id:ansistring; //id: ID
            group.id:=groupID;
            //NVSName:ansistring; //name: String
            group.NVSName:=safeString(ja[i].FindPath('name'));
            //NVSValue:ansistring; //value
            group.NVSValue:=safeString(ja[i].FindPath('value'));

            try
              q:=365;
              s:=safeString(ja[i].FindPath('days'));
              if s<>'' then q:=myStrToInt(s) else q:=365;
            except
              q:=365;
            end;
            group.NVSDays:=q;

            //amount:dword;   //amount: Float
            s:=safeString(ja[i].FindPath('amount'));
            if s<>'' then group.amount:=trunc(1000000*myStrToFloat(s))
                     else group.amount:=0;
            //ownerAddress:ansistring; //address
            group.ownerAddress:=safeString(ja[i].FindPath('address'));
            //time:dword;
            //LockTime:dword;
            //  dpo: String
            //  time: Int
            //TaskType: String; //type
            group.TaskType:=safeString(ja[i].FindPath('type'));
            //  group: ссылка на группу, при запросе можно получать поля, например id

            group.Tasks.updateFromServer(groupID);
            group.fUpdated:=false;
            callNotify('newtask');
          end;
        end;
     end;
     //fLastUpdateTimeTX:=now;
     //callNotify
     myUpdate(self);
    end;
  end else
  if pos('transactionlist_',sender.id+'_')=1 then begin
   //this is a tasks list
   //{ "data" : { "transactionlist" : [{ "address" : "address", "amount" : 1.000
   // ... , "group" : { "id" : "5bd87ebef3a6087e32ee70b6" }
   if js<>nil then begin
    e:=js.FindPath('data.transactionlist');
    if (e<>nil) and (e is tJSONArray) then begin
           ja:=tJSONArray(e);
           for i:=0 to ja.Count-1 do begin
             //Task. Do we have it?
             taskID:=ja[i].FindPath('id').AsString;
             task:=nil;
             for j:=0 to Count-1 do
               if items[j] is tEmerAPIServerTask then
                  if uppercase(tEmerAPIServerTask(items[j]).id) =uppercase(taskID) then begin
                     task:=tEmerAPIServerTask(items[j]);
                     break;
                  end;

             groupID:='';
             e:=ja[i].FindPath('group.id');
             if e<>nil then groupID:=e.AsString;

             if task = nil then begin
               task:=tEmerAPIServerTask.create(self);
               taskidx:=fItems.add(task);

               //Comment:string;  //comment: String
               task.Comment:=safeString(ja[i].FindPath('comment'));
               //id:ansistring; //id: ID
               //task.id:=groupID;
               //NVSName:ansistring; //name: String
               task.NVSName:=safeString(ja[i].FindPath('name'));
               //NVSValue:ansistring; //value
               task.NVSValue:=safeString(ja[i].FindPath('value'));

               try
                 q:=365;
                 s:=safeString(ja[i].FindPath('days'));
                 if s<>'' then q:=myStrToInt(s) else q:=365;
               except
                 q:=365;
               end;
               task.NVSDays:=q;

               //amount:dword;   //amount: Float
               s:=safeString(ja[i].FindPath('amount'));
               if s<>'' then task.amount:=trunc(1000000*myStrToFloat(s))
                        else task.amount:=0;
               //ownerAddress:ansistring; //address
               task.ownerAddress:=safeString(ja[i].FindPath('address'));
               //time:dword;
               //LockTime:dword;
               //  dpo: String
               //  time: Int
               //TaskType: String; //type
               task.TaskType:=safeString(ja[i].FindPath('type'));
               task.fUpdated:=true;
               if fValidateAfterCreate then validateTask(taskidx);
               callNotify('newtask');
             end;
           end;
        end;
      myUpdate(self);
   end;
  end;

  fLastUpdateTime:=now;
end;

procedure tEmerAPIServerTaskList.updateFromServer(groupID:ansistring='');
begin
  //read tasks
  if fEmerAPI=nil then raise exception.Create('tEmerAPIServerTaskList.updateFromServer: fEmerAPI=nil');



//  if fEmerAPI.EmerAPIConnetor.sendQueryAsync();
 if groupID='' then
   //this is a main list
   fEmerAPI.EmerAPIConnetor.sendQueryAsync(
     'query { transactiongrouplist {'#13#10+
     '  address'#13#10+
     '  amount'#13#10+
     '  comment'#13#10+
     '  id'#13#10+
     '  name'#13#10+
     '  time'#13#10+
     '  type'#13#10+
     '  value'#13#10+
     '}}'
    , nil  //GetJSON('{"action":"start",scanobjects:['+s+']}')
    ,@onAsyncQueryDoneHandler,'transactiongrouplist_'+fEmerAPI.EmerAPIConnetor.getNextID)
  else
    //this is a task list for a group groupID
    fEmerAPI.EmerAPIConnetor.sendQueryAsync(
    'query {transactionlist (group:"'+groupID+'") {'#13#10+
    '    address'#13#10+
    '    amount'#13#10+
    '    comment'#13#10+
//    '    dpo'#13#10+
    '    id'#13#10+
    '    name'#13#10+
    '    time'#13#10+
    '    type'#13#10+
    '    value'#13#10+
    '    group {'#13#10+
    '	    id'#13#10+
    '	  }'#13#10+
    '  }}'
   , nil  //GetJSON('{"action":"start",scanobjects:['+s+']}')
   ,@onAsyncQueryDoneHandler,'transactionlist_'+groupID+'_'+fEmerAPI.EmerAPIConnetor.getNextID)
   ;
end;

procedure tEmerAPIServerTaskList.validateTask(Index:integer=-1); //-1 for all
var i:integer;
begin
 if (index<-1) or (index>=fItems.count) then raise exception.Create('tEmerAPIServerTaskList.validateTask: index out of bounds');

 if index<0 then
   for i:=0 to fItems.count-1 do
     tBaseEmerAPIServerTask(fItems[i]).validateTask()
 else
   tBaseEmerAPIServerTask(fItems[index]).validateTask();


end;

constructor tEmerAPIServerTaskList.create(mEmerAPI:tEmerAPI; setValidateAfterCreate:boolean=true);
begin
 inherited create();
 fEmerAPI:=mEmerAPI;
 fItems:=tList.Create;
 fvalidateAfterCreate:=setValidateAfterCreate;
end;

procedure tEmerAPIServerTaskList.clearList;
var i:integer;
begin
 for i:=0 to fItems.Count-1 do
   tBaseEmerAPIServerTask(fItems[i]).Free;
 fItems.Clear;
end;

procedure tEmerAPIServerTaskList.delete(Index: integer);
begin
  if (index<0) or (index>=fItems.count) then raise exception.Create('tEmerAPIServerTaskList.delete: index out of bounds');
  tBaseEmerAPIServerTask(fItems[index]).Free;
  fItems.Delete(index);
end;

destructor tEmerAPIServerTaskList.destroy;
begin
  clearList;
  fItems.Free;
  inherited;
end;

function tEmerAPIServerTaskList.getItem(Index: integer):tBaseEmerAPIServerTask;
begin
  if (Index<0) or (Index>=Count) then raise exception.Create('tEmerAPIServerTaskList.getItem: index out of bounds');
  result:=tBaseEmerAPIServerTask(fItems[Index]);
end;

function tEmerAPIServerTaskList.getCount:integer;
begin
  result:=fItems.Count;
end;


end.

